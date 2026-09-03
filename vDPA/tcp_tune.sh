# Increase maximum socket receive and send buffer sizes for high-speed links
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.core.rmem_default=33554432
sudo sysctl -w net.core.wmem_default=33554432
sudo sysctl -w net.core.optmem_max=67108864

# Increase Linux auto-tuning TCP buffer limits (min, default, max in bytes)
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432"

# Increase the processor input queue to handle heavy burst traffic without dropping packets
sudo sysctl -w net.core.netdev_max_backlog=250000

# Increase maximumorphaned sockets and connection queue backlog
sudo sysctl -w net.core.somaxconn=10240

# Enable BBR Congestion Control (if available on your kernel version >= 4.9)
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
