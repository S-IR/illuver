package main
import "core:os"
import sdl "vendor:sdl3"

screenWidth: u32 = 1280
screenHeight: u32 = 720

seed: u64 = 123
// device: ^sdl.GPUDevice
window: ^sdl.Window

camera: Camera
dt: f64
totalTime: f64 = 0


near_plane: f32 : 0.2
far_plane: f32 : 160.0
NUM_CORES := -1
