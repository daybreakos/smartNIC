// use anyhow::Context as _;
use aya::{
    maps::Array,
    programs::{xdp::XdpMode, Xdp},
    Ebpf,
};
use clap::Parser;
use log::{debug, warn, info};
use tokio::signal;

//#[rustfmt::skip]

#[derive(Debug, Parser)]
struct Opt {
    #[clap(short, long, default_value = "eth0")]
    iface: String,

    /// Watch Mode: stay attached and continueously print pkt count updates 
    #[clap(long)]
    watch: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let opt = Opt::parse();

    env_logger::init();

    // Bump the memlock rlimit. This is needed for older kernels that don't use the
    // new memcg based accounting, see https://lwn.net/Articles/837122/
    bump_memlock_rlimit();

    // This will include your eBPF object file as raw bytes at compile-time and load it at
    // runtime. This approach is recommended for most real-world use cases. If you would
    // like to specify the eBPF program at runtime rather than at compile-time, you can
    // reach for `Bpf::load_file` instead.
    let mut ebpf = Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/xdp-mode"
    )))?;

    // match aya_log::EbpfLogger::init(&mut ebpf) {
    //     Err(e) => {
    //         // This can happen if you remove all log statements from your eBPF program.
    //         warn!("failed to initialize eBPF logger: {e}");
    //     }
    //     Ok(logger) => {
    //         let mut logger =
    //             tokio::io::unix::AsyncFd::with_interest(logger, tokio::io::Interest::READABLE)?;
    //         tokio::task::spawn(async move {
    //             loop {
    //                 let mut guard = logger.readable_mut().await.unwrap();
    //                 guard.get_inner_mut().flush();
    //                 guard.clear_ready();
    //             }
    //         });
    //     }
    // }
    //let Opt { iface } = opt;


    let program: &mut Xdp = ebpf.program_mut("xdp_mode").unwrap().try_into()?;
    program.load()?;
    // program.attach(&iface, XdpMode::default())
    //     .context("failed to attach the XDP program with default mode - try changing XdpMode::default() to XdpMode::Skb")?;

    // Ordered list of modes from strongest (Hardware Offload) to generic (Skb)
    //let modes = [XdpMode::Offload, XdpMode::Driver, XdpMode::Skb];
    let modes = [XdpMode::Hardware, XdpMode::Driver, XdpMode::Skb];

    let mut attached_mode = None;
    let mut _link_id = None;

    // Probe interface driver for supported modes using XdpMode directly
    for mode in modes {
        info!("Probing XDP mode: {:?}", mode);
        
        // match program.attach_to_iface(&opt.iface, mode) {
        match program.attach(&opt.iface, mode) {
            Ok(link) => {
                info!("Successfully attached in {:?} mode", mode);
                attached_mode = Some(mode);
                _link_id = Some(link);
                break; // Stop probing once attached in the best supported mode
            }
            Err(e) => {
                warn!("Failed to attach in {:?} mode: {}", mode, e);
            }
        }
    }

    let active_mode = match attached_mode {
        Some(mode) => mode,
        None => {
            return Err(anyhow::anyhow!(
                "Failed to attach XDP program to {} in any supported mode.",
                opt.iface
            )
            .into());
        }
    };
    println!("\n==========================================");
    println!("Interface      : {}", opt.iface);
    println!("Strongest Mode : {:?}", active_mode);
    println!("==========================================\n");

    if opt.watch {
        println!("Watch mode enabled. Printing live packet counts (Ctrl+C to exit)...");
     
        //let mut packet_count: Array<_, u64> = Array::try_from(ebpf.map_mut("PACKET_COUNT").unwrap())?;
        let packet_count: Array<_, u64> = Array::try_from(ebpf.map_mut("PACKET_COUNT").unwrap())?;
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(1));
     
        tokio::select! {
            _ = async {
                loop {
                    interval.tick().await;
                    if let Ok(count) = packet_count.get(&0, 0) {
                        println!("[{}] Total Packets Processed: {}", opt.iface, count);
                    }
                }
            } => {},
            _ = signal::ctrl_c() => {
                println!("\nCtrl+C received. Detaching XDP program and exiting...");
            }
        }
    } else {
        println!("Probe complete. Exiting (program detaches automatically).");
    }

    // let ctrl_c = signal::ctrl_c();
    // println!("Waiting for Ctrl-C...");
    // ctrl_c.await?;
    // println!("Exiting...");

    Ok(())
}

fn bump_memlock_rlimit () {
    let rlim = libc::rlimit {
        rlim_cur: libc::RLIM_INFINITY,
        rlim_max: libc::RLIM_INFINITY,
    };
    let ret = unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &rlim) };
    if ret != 0 {
        debug!("remove limit on locked memory failed, ret is: {ret}");
    }
}
