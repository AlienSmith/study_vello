let COARSE_WGS = 256u;

#import bump
@group(0) @binding(0)
var<storage> bump: BumpAllocators;

@group(0) @binding(1)
var<storage, read_write> indirect: IndirectCount;

@compute @workgroup_size(1)
fn main() {
    let cubic_count = atomicLoad(&bump.cubics);
    indirect.count_x = (cubic_count + COARSE_WGS - 1u)/ COARSE_WGS;
    indirect.count_y = 1u;
    indirect.count_z = 1u;
}
