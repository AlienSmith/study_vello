// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Also licensed under MIT license, at your choice.

//! Load rendering shaders.

mod preprocess;

use std::collections::HashSet;

#[cfg(feature = "wgpu")]
use wgpu::Device;

use crate::{ cpu_shader, engine::{ BindType, Error, ImageFormat, ShaderId } };

#[cfg(feature = "wgpu")]
use crate::wgpu_engine::WgpuEngine;

macro_rules! shader {
    (
        $name:expr
    ) => {&{
        let shader = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/shader/",
            $name,
            ".wgsl"
        ));
        #[cfg(feature = "hot_reload")]
        let shader = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/shader/",
            $name,
            ".wgsl"
        ))
        .unwrap_or_else(|e| {
            eprintln!(
                "Failed to read shader {name}, error falling back to version at compilation time. Error: {e:?}",
                name = $name
            );
            shader.to_string()
        });
        shader
    }};
}

// Shaders for the full pipeline
pub struct FullShaders {
    pub pathtag_reduce: ShaderId,
    pub pathtag_reduce2: ShaderId,
    pub pathtag_scan1: ShaderId,
    pub pathtag_scan: ShaderId,
    pub pathtag_scan_large: ShaderId,
    pub bbox_clear: ShaderId,
    pub pathseg: ShaderId,
    pub draw_reduce: ShaderId,
    pub draw_leaf: ShaderId,
    pub clip_reduce: ShaderId,
    pub clip_leaf: ShaderId,
    pub flatten: ShaderId,
    pub pattern_setup: ShaderId,
    pub pattern: ShaderId,
    pub particles: ShaderId,
    pub binning: ShaderId,
    pub tile_alloc: ShaderId,
    pub path_coarse_counter: ShaderId,
    pub path_coarse: ShaderId,
    pub backdrop: ShaderId,
    //use for coarse segmentation logic
    pub coarse_counter: ShaderId,
    pub coarse_setup: ShaderId,
    pub coarse_setup_debug: ShaderId,
    #[cfg(feature = "coarse_segmentation")]
    pub coarse: ShaderId,
    pub fine_setup: ShaderId,
    #[cfg(feature = "coarse_segmentation")]
    pub fine: ShaderId,
    pub compose: ShaderId,
    //use for ptcl segmentation logic
    pub coarse_original: ShaderId,
    pub fine_setup_original: ShaderId,
    pub fine_original: ShaderId,
    pub compose_original: ShaderId,
}

#[cfg(feature = "wgpu")]
pub fn full_shaders(
    device: &Device,
    engine: &mut WgpuEngine,
    use_cpu: bool
) -> Result<FullShaders, Error> {
    let imports = SHARED_SHADERS.iter().copied().collect::<std::collections::HashMap<_, _>>();
    let empty = HashSet::new();
    let mut full_config = HashSet::new();
    full_config.insert("full".into());

    #[cfg(feature = "ptcl_segmentation")]
    full_config.insert("ptcl_segmentation".into());

    let mut small_config = HashSet::new();
    small_config.insert("full".into());
    small_config.insert("small".into());
    let pathtag_reduce = engine.add_shader(
        device,
        "pathtag_reduce",
        preprocess::preprocess(shader!("pathtag_reduce"), &full_config, &imports).into(),
        &[BindType::Uniform, BindType::BufReadOnly, BindType::Buffer]
    )?;
    if use_cpu {
        engine.set_cpu_shader(pathtag_reduce, cpu_shader::pathtag_reduce);
    }
    let pathtag_reduce2 = engine.add_shader(
        device,
        "pathtag_reduce2",
        preprocess::preprocess(shader!("pathtag_reduce2"), &full_config, &imports).into(),
        &[BindType::BufReadOnly, BindType::Buffer]
    )?;
    let pathtag_scan1 = engine.add_shader(
        device,
        "pathtag_scan1",
        preprocess::preprocess(shader!("pathtag_scan1"), &full_config, &imports).into(),
        &[BindType::BufReadOnly, BindType::BufReadOnly, BindType::Buffer]
    )?;
    let pathtag_scan = engine.add_shader(
        device,
        "pathtag_scan",
        preprocess::preprocess(shader!("pathtag_scan"), &small_config, &imports).into(),
        &[BindType::Uniform, BindType::BufReadOnly, BindType::BufReadOnly, BindType::Buffer]
    )?;
    let pathtag_scan_large = engine.add_shader(
        device,
        "pathtag_scan",
        preprocess::preprocess(shader!("pathtag_scan"), &full_config, &imports).into(),
        &[BindType::Uniform, BindType::BufReadOnly, BindType::BufReadOnly, BindType::Buffer]
    )?;
    let bbox_clear = engine.add_shader(
        device,
        "bbox_clear",
        preprocess::preprocess(shader!("bbox_clear"), &empty, &imports).into(),
        &[BindType::Uniform, BindType::Buffer]
    )?;
    let pathseg = engine.add_shader(
        device,
        "pathseg",
        preprocess::preprocess(shader!("pathseg"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;
    let draw_reduce = engine.add_shader(
        device,
        "draw_reduce",
        preprocess::preprocess(shader!("draw_reduce"), &empty, &imports).into(),
        &[BindType::Uniform, BindType::BufReadOnly, BindType::Buffer]
    )?;
    let draw_leaf = engine.add_shader(
        device,
        "draw_leaf",
        preprocess::preprocess(shader!("draw_leaf"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;
    let clip_reduce = engine.add_shader(
        device,
        "clip_reduce",
        preprocess::preprocess(shader!("clip_reduce"), &empty, &imports).into(),
        &[BindType::BufReadOnly, BindType::BufReadOnly, BindType::Buffer, BindType::Buffer]
    )?;
    let clip_leaf = engine.add_shader(
        device,
        "clip_leaf",
        preprocess::preprocess(shader!("clip_leaf"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;

    let flatten = engine.add_shader(
        device,
        "flatten",
        preprocess::preprocess(shader!("flatten"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::BufReadOnly,
        ]
    )?;

    let pattern_setup = engine.add_shader(
        device,
        "pattern_setup",
        preprocess::preprocess(shader!("pattern_setup"), &empty, &imports).into(),
        &[BindType::Uniform, BindType::Buffer, BindType::Buffer]
    )?;

    let pattern = engine.add_shader(
        device,
        "pattern",
        preprocess::preprocess(shader!("pattern"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;

    let particles = engine.add_shader(
        device,
        "particles",
        preprocess::preprocess(shader!("particles"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::BufReadOnly,
        ]
    )?;

    let binning = engine.add_shader(
        device,
        "binning",
        preprocess::preprocess(shader!("binning"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;
    let tile_alloc = engine.add_shader(
        device,
        "tile_alloc",
        preprocess::preprocess(shader!("tile_alloc"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;

    let path_coarse_counter = engine.add_shader(
        device,
        "path_coarse_counter",
        preprocess::preprocess(shader!("path_coarse_counter"), &full_config, &imports).into(),
        &[BindType::Buffer, BindType::Buffer]
    )?;

    let path_coarse = engine.add_shader(
        device,
        "path_coarse_full",
        preprocess::preprocess(shader!("path_coarse_full"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::BufReadOnly,
        ]
    )?;
    let backdrop = engine.add_shader(
        device,
        "backdrop_dyn",
        preprocess::preprocess(shader!("backdrop_dyn"), &empty, &imports).into(),
        &[BindType::Uniform, BindType::BufReadOnly, BindType::Buffer]
    )?;
    let coarse_counter = engine.add_shader(
        device,
        "coarse_counter",
        preprocess::preprocess(shader!("coarse_counter"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
        ]
    )?;

    let coarse_setup = engine.add_shader(
        device,
        "coarse_setup",
        preprocess::preprocess(shader!("coarse_setup"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Buffer,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
        ]
    )?;

    let coarse_setup_debug = engine.add_shader(
        device,
        "coarse_setup_debug",
        preprocess::preprocess(shader!("coarse_setup_debug"), &empty, &imports).into(),
        &[BindType::Uniform, BindType::Buffer, BindType::Buffer, BindType::Buffer]
    )?;
    #[cfg(feature = "coarse_segmentation")]
    let coarse = engine.add_shader(
        device,
        "coarse",
        preprocess::preprocess(shader!("coarse"), &empty, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            BindType::Buffer,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
        ]
    )?;
    let fine_setup = engine.add_shader(
        device,
        "fine_setup",
        preprocess::preprocess(shader!("fine_setup"), &full_config, &imports).into(),
        &[BindType::Uniform, BindType::Buffer, BindType::Buffer]
    )?;
    #[cfg(feature = "coarse_segmentation")]
    let fine = engine.add_shader(
        device,
        "fine",
        preprocess::preprocess(shader!("fine"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::ImageRead(ImageFormat::Rgba8),
            BindType::BufReadOnly,
            BindType::ImageRead(ImageFormat::Rgba8),
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
        ]
    )?;
    //we need a separate shader because no clear way to share barrier between workgroup
    let compose = engine.add_shader(
        device,
        "compose",
        preprocess::preprocess(shader!("compose"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Image(ImageFormat::Rgba8),
            BindType::BufReadOnly,
            BindType::Buffer,
        ]
    )?;

    let coarse_original = engine.add_shader(
        device,
        "coarse_original",
        preprocess::preprocess(shader!("coarse_original"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::Buffer,
            BindType::Buffer,
            #[cfg(feature = "ptcl_segmentation")] BindType::Buffer,
        ]
    )?;
    let fine_setup_original = engine.add_shader(
        device,
        "fine_setup_original",
        preprocess::preprocess(shader!("fine_setup_original"), &full_config, &imports).into(),
        &[BindType::Uniform, BindType::Buffer, BindType::Buffer, BindType::Buffer]
    )?;
    let fine_original = engine.add_shader(
        device,
        "fine_original",
        preprocess::preprocess(shader!("fine_original"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::BufReadOnly,
            BindType::ImageRead(ImageFormat::Rgba8),
            BindType::ImageRead(ImageFormat::Rgba8),
            BindType::Buffer,
            #[cfg(feature = "ptcl_segmentation")] BindType::Buffer,
            #[cfg(not(feature = "ptcl_segmentation"))] BindType::Image(ImageFormat::Rgba8),
        ]
    )?;
    let compose_original = engine.add_shader(
        device,
        "compose_original",
        preprocess::preprocess(shader!("compose_original"), &full_config, &imports).into(),
        &[
            BindType::Uniform,
            BindType::Image(ImageFormat::Rgba8),
            BindType::Buffer,
            BindType::BufReadOnly,
        ]
    )?;
    Ok(FullShaders {
        pathtag_reduce,
        pathtag_reduce2,
        pathtag_scan,
        pathtag_scan1,
        pathtag_scan_large,
        bbox_clear,
        pathseg,
        draw_reduce,
        draw_leaf,
        clip_reduce,
        clip_leaf,
        flatten,
        pattern_setup,
        pattern,
        particles,
        binning,
        tile_alloc,
        path_coarse_counter,
        path_coarse,
        backdrop,
        coarse_counter,
        coarse_setup,
        coarse_setup_debug,
        #[cfg(feature = "coarse_segmentation")] coarse,
        fine_setup,
        #[cfg(feature = "coarse_segmentation")] fine,
        compose,
        coarse_original,
        fine_setup_original,
        fine_original,
        compose_original,
    })
}

macro_rules! shared_shader {
    ($name:expr) => {
        (
            $name,
            include_str!(concat!("../shader/shared/", $name, ".wgsl")),
        )
    };
}

const SHARED_SHADERS: &[(&str, &str)] = &[
    shared_shader!("bbox"),
    shared_shader!("blend"),
    shared_shader!("bump"),
    shared_shader!("clip"),
    shared_shader!("config"),
    shared_shader!("cubic"),
    shared_shader!("drawtag"),
    shared_shader!("pathtag"),
    shared_shader!("ptcl"),
    shared_shader!("segment"),
    shared_shader!("tile"),
    shared_shader!("transform"),
    shared_shader!("util"),
];
