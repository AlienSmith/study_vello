#import bump
#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(2)
var<storage, read_write> indirect: IndirectCount;
let PATTERN_WGS = 256u;
@compute @workgroup_size(1)
fn main(){
    let start = config.n_path;
    let end = atomicLoad(&bump.cubics);
    bump.intermidiate.x = end;
    indirect.count_x = (end - start + PATTERN_WGS - 1u)/ PATTERN_WGS;
    indirect.count_y = 1u;
    indirect.count_z = 1u;
}