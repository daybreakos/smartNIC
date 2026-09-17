   sudo ip link add veth0 type veth peer name veth1
   sudo ip link set veth0 up
   sudo ip netns add ns1
   sudo ip link set veth1 netns ns1
   sudo ip netns exec ns1 ip link set veth1 up
   sudo ip addr add 10.0.0.1/24 dev veth0
   sudo ip netns exec ns1 ip addr add 10.0.0.2/24 dev veth1

echo "Terminal 1: sudo ./afxdp_icmp_user veth0 0 xdp_afxdp_icmp_kern.o"
echo "Terminal 2: sudo ip netns exec ns1 ping 10.0.0.1"
echo "hping3 ICMP flood"
echo "Terminal 2: sudo ip netns exec ns1 hping3 --icmp --flood 10.0.0.1"
echo "-----------"
echo "Reset setup: sudo ip netns del ns1 "
echo "           : sudo ip link delete veth0"
