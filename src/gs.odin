package main
import "core:os"
import "core:time"
import sdl "vendor:sdl3"

screenWidth: u32 = 1280
screenHeight: u32 = 720

seed: u64 = 123
// device: ^sdl.GPUDevice
window: ^sdl.Window

camera: Camera
dt: f64
totalTime: f64 = 0


near_plane: f32 : 0.1
far_plane: f32 : 160.0
NUM_CORES := -1


SIMULATION_TICK_RATE :: 60


LifeInterval :: time.Duration(1.75 * f64(time.Second))
WisdomInterval :: time.Duration(2.1 * f64(time.Second))
LightInterval :: time.Duration(2.3 * f64(time.Second))

LastLifeTick: time.Tick
LastWisdomTick: time.Tick
LastLightTick: time.Tick
