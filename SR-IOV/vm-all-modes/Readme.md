# Test 1: SR-IOV eSwitch Legacy Mode
sudo ./t2_host_setup.sh --mode legacy
./t2_build_guest_image.sh 1
./t2_build_guest_image.sh 2
./t2_launch_vm.sh 1
./t2_launch_vm.sh 2
./t2_run_benchmarks.sh
sudo ./t2_host_reset.sh

# Test 2: SR-IOV Switchdev OVS HW-Offload Mode
sudo ./t2_host_setup.sh --mode ovs
./t2_launch_vm.sh 1
./t2_launch_vm.sh 2
./t2_run_benchmarks.sh
sudo ./t2_host_reset.sh

# Test 3: SR-IOV Switchdev TC Flower Mode
sudo ./t2_host_setup.sh --mode tc
./t2_launch_vm.sh 1
./t2_launch_vm.sh 2
./t2_run_benchmarks.sh
sudo ./t2_host_reset.sh
