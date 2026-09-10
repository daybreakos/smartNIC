#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::xdp_action, 
    macros::{map, xdp}, 
    maps::Array,
    programs::XdpContext,
};
// use aya_log_ebpf::info;

#[map]
static PACKET_COUNT: Array<u64> = Array::with_max_entries(1,0);

//#[xdp]
// pub fn xdp_mode(ctx: XdpContext) -> u32 {
//     match try_xdp_mode(ctx) {
//         Ok(ret) => ret,
//         Err(_) => xdp_action::XDP_ABORTED,
//     }
// }
//
// fn try_xdp_mode(ctx: XdpContext) -> Result<u32, u32> {
//     //info!(&ctx, "received a packet");
//     Ok(xdp_action::XDP_PASS)
// }

#[xdp]
pub fn xdp_mode(_ctx: XdpContext) -> u32 {
    if let Some(count) = PACKET_COUNT.get_ptr_mut(0) {
        unsafe {
            *count += 1;
        }
    }
    xdp_action::XDP_PASS
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
