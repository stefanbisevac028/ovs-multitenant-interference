/*
 * ovs_instance_cpu.bpf.c - kernel CPU vreme po OvS instanci (po mreznom namespace-u)
 *
 * Svaka OvS instanca (tier0 na hostu, ovs-1..3 u kontejnerima) ima svoj kernel
 * datapath u svom mreznom namespace-u. Svaki paket koji neki datapath obradi
 * ulazi kroz ovs_vport_receive(vport, skb, tun_info): ekstrakcija flow kljuca,
 * lookup u flow tabeli (ili upcall ka ovs-vswitchd), izvrsavanje akcija i
 * izlaz na port (npr. veth_xmit / dev_queue_xmit). Vreme od ulaza do povratka
 * iz ove funkcije = kernel CPU te instance za taj paket.
 *
 * Instanca se prepoznaje po inode-u mreznog namespace-a ulaznog uredjaja
 * (skb->dev->nd_net.net->ns.inum), sto je jedinstveno (ifindex nije: svaki
 * namespace ima svoje ifindex-e).
 *
 * Ugnjezdeni pozivi na istom CPU-u (paket iz jednog datapath-a odmah obradjen
 * u drugom) se racunaju ekskluzivno: roditelju se oduzima vreme deteta.
 * Datapath se izvrsava sa iskljucenim BH, pa per-CPU stek ne moze da se pomesa.
 */

#include <uapi/linux/ptrace.h>
#include <linux/skbuff.h>
#include <linux/netdevice.h>
#include <net/net_namespace.h>

#define MAX_DEPTH 4

struct frame_t {
    u64 ts;
    u64 child_ns;
    u32 inum;
};

struct stack_t {
    u32 depth;
    struct frame_t f[MAX_DEPTH];
};

struct val_t {
    u64 ns;       // ekskluzivno CPU vreme [ns]
    u64 packets;
    u64 bytes;
};

BPF_PERCPU_ARRAY(stacks, struct stack_t, 1);
BPF_HASH(per_netns, u32, struct val_t, 64);
BPF_ARRAY(overflow, u64, 1);

int on_entry(struct pt_regs *ctx)
{
    struct sk_buff *skb = (struct sk_buff *)PT_REGS_PARM2(ctx);
    struct net_device *dev = NULL;
    struct net *net = NULL;
    u32 inum = 0, len = 0;
    int zero = 0;

    bpf_probe_read_kernel(&dev, sizeof(dev), &skb->dev);
    bpf_probe_read_kernel(&len, sizeof(len), &skb->len);
    if (dev) {
        bpf_probe_read_kernel(&net, sizeof(net), &dev->nd_net.net);
        if (net)
            bpf_probe_read_kernel(&inum, sizeof(inum), &net->ns.inum);
    }

    struct stack_t *st = stacks.lookup(&zero);
    if (!st)
        return 0;
    u32 d = st->depth;
    if (d >= MAX_DEPTH) {
        overflow.increment(zero);
        st->depth = d + 1;   // povratak ce samo smanjiti dubinu
        return 0;
    }
    st->f[d].ts = bpf_ktime_get_ns();
    st->f[d].child_ns = 0;
    st->f[d].inum = inum;
    st->depth = d + 1;

    struct val_t zv = {};
    struct val_t *v = per_netns.lookup_or_try_init(&inum, &zv);
    if (v) {
        __sync_fetch_and_add(&v->packets, 1);
        __sync_fetch_and_add(&v->bytes, len);
    }
    return 0;
}

int on_return(struct pt_regs *ctx)
{
    int zero = 0;
    struct stack_t *st = stacks.lookup(&zero);
    if (!st || st->depth == 0)
        return 0;
    u32 d = st->depth - 1;
    st->depth = d;
    if (d >= MAX_DEPTH)
        return 0;

    u64 delta = bpf_ktime_get_ns() - st->f[d].ts;
    u64 excl = delta > st->f[d].child_ns ? delta - st->f[d].child_ns : 0;
    u32 inum = st->f[d].inum;
    u32 p = d - 1;
    if (d > 0 && p < MAX_DEPTH)
        st->f[p & (MAX_DEPTH - 1)].child_ns += delta;

    struct val_t *v = per_netns.lookup(&inum);
    if (v)
        __sync_fetch_and_add(&v->ns, excl);
    return 0;
}
