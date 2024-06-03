use anyhow::Result;

fn main() -> Result<()> {
    with_winit::main()
}

#[test]
fn print() {
    let value = 259522560;
    let tile_index = value >> 16;
    let begin_clip_count = (value >> 12) & 0xf;
    let clip_index = value & 0xfff;
    println!(
        "tile_index:{}, begin_clip_count:{}, clip_index:{}",
        tile_index,
        begin_clip_count,
        clip_index
    );
}
