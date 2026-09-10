- XDP support mode:  [Done]
- Update real-time pkt-per-second calculator:  [Done]
- Packet counter  :  [FollowUp]
   Required changes to handle high speed NIC's
   - change map from `Array` with `PerCpuArray`, as Array can cause 
     cache-inline bouncing across CPU Cores. 
   - `PerCpuArray`: distributes counter tracing to local CPUs:
   ```rust
   // eBPF Kernel Space
   #[map]
   static PACKET_COUNT: PerCpuArray<u64> = PerCpuArray::with_max_entries(1, 0);

   // User Space Aggregation
   let packet_count: PerCpuArray<_, u64> = PerCpuArray::try_from(ebpf.map_mut("PACKET_COUNT").unwrap())?;
   let values = packet_count.get(&0, 0)?;
   let total: u64 = values.iter().sum();
   ```

- Unbind Hook (ctrl_c handling)
    Calling link.take() inside the signal handler ensures clean detachment during SIGINT shutdown:
    ```rust 
    _ = signal::ctrl_c() => {
        println!("\nCtrl+C received. Detaching XDP program...");
        drop(_link); // explicit unbinding
    }
    ```



