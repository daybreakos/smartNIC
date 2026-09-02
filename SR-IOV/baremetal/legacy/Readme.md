
# GB-10 SR-IOV

Note: make sure to eSwitch is set to legacy mode for this setting:

sudo devlink dev eswitch set pci/0000:01:00.0 mode legacy
sudo devlink dev eswitch set pci/0002:01:00.1 mode legacy

Enable sriov funtion:
echo 1 | sudo tee /sys/class/net/enp1s0f0np0/device/sriov_numvfs
echo 1 | sudo tee /sys/class/net/enP2p1s0f1np1/device/sriov_numvfs

Add network namespaces:
sudo ip netns add left-ns
sudo ip netns add right-ns

sudo ip link set enp1s0f0v0 netns left-ns
sudo ip link set enP2p1s0f1v0 netns right-ns

Configure the namespaces:
sudo ip netns exec left-ns ip addr add 10.0.0.1/24 dev enp1s0f0v0
sudo ip netns exec left-ns ip link set enp1s0f0v0 up
sudo ip netns exec left-ns ip link set lo up

sudo ip netns exec right-ns ip addr add 10.0.0.2/24 dev enP2p1s0f1v0
sudo ip netns exec right-ns ip link set enP2p1s0f1v0 up
sudo ip netns exec right-ns ip link set lo up

Test connectivity between namespaces:
sudo ip netns exec left-ns ping 10.0.0.2



