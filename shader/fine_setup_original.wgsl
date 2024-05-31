#import bump
#import config
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> fine_index: array<u32>;

@group(0) @binding(2)
var<storage, read_write> indirect: IndirectCount;

@group(0) @binding(3)
var<storage, read_write> bump: BumpAllocators;

@compute @workgroup_size(1)
fn main() {
    let end = config.width_in_tiles * config.height_in_tiles;
    var count = 0u;
    for (var i = 0u; i < end; i += 1u) {
        let space = fine_index[i];
        count += space;
        fine_index[i] = count;
    }
    if count > config.ptcl_slice_count {
        count = 0u;
        atomicOr(&bump.failed, STAGE_FINE_SETUP);
    }
    indirect.count_x = count;
    indirect.count_y = 1u;
    indirect.count_z = 1u;
}