// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Set up dispatch size for path count stage.

#import bump
#import config
#import ptcl
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> fine_index: array<u32>;

@group(0) @binding(2)
var<storage, read_write> indirect: IndirectCount;

@group(0) @binding(3)
var<storage, read_write> bump: BumpAllocators;

// Partition size for path count stage
let WG_SIZE = 256u;

@compute @workgroup_size(1)
fn main() {

    var count = atomicLoad(&bump.ptcl) / PTCL_INCREMENT;
    atomicStore(&bump.fine_slices, count);

    //to much slices don't have enough space to store the results.
    if count > config.ptcl_slice_count {
        count = 0u;
        atomicOr(&bump.failed, STAGE_FINE_SETUP);
    }
    
    indirect.count_x = count;
    indirect.count_y = 1u;
    indirect.count_z = 1u;
}
