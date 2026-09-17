echo "create network namespace : ns1"
sudo ip netns add ns1
echo "Adding enp1s0f1np1 to namespace ns1"
sudo ip link set enp1s0f1np1 netns ns1
#sudo ip link set enp1s0f0np0 up
#sudo ip addr add 10.0.0.1/24 dev enp1s0f0np0
echo "Assign enp1s0f1np1 : 192.168.100.12/24 "
sudo ip netns exec ns1 ip link set enp1s0f1np1 up
sudo ip netns exec ns1 ip addr add 192.168.100.12/24 dev enp1s0f1np1
sudo ip netns exec ns1 ip link set lo up

echo "Make sure enp1s0f0np0 as IP address setup ex: 192.168.100.10/24"
echo "Run the AF_XDP ICMP Redirect prog on enp1s0f0np0"
echo "Terminal 1: sudo ./afxdp_icmp_user enp1s0f0np0 0 xdp_afxdp_icmp_kern.o"
echo "Terminal 2: sudo ip netns exec ns1 hping3 --icmp --flood 192.168.100.10"
echo "hping3 TCP instead of ICMP "
echo "Terminal 2: sudo ip netns exec ns1 hping3 --flood 192.168.100.10"
echo "-----------"
echo "Reset setup: sudo ip netns del ns1 "

