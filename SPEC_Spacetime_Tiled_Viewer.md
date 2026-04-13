Claim 1: The tile server can serve spatial rectangles from recorded frames via HTTP
Type: ARCHITECTURAL
Depends on: None

Claim 2: Morton Z-curve ordering ensures any spatial rectangle maps to contiguous bytes on disk
Type: MATHEMATICAL
Depends on: None

Claim 3: Downsampling a 32768x32768 grid to 2048x2048 produces a visually faithful representation
Type: EMPIRICAL
Depends on: 1

Claim 4: The savanna_live.html viewer works unmodified when the tile server serves savanna_state.bin format
Type: ARCHITECTURAL
Depends on: 1

Claim 5: T and G keys control a base_period parameter that sets the atomic tick rate at zoom=1
Type: ARCHITECTURAL
Depends on: None

Claim 6: Levy superdiffusion scaling t ~ 1/zoom^1.5 correctly couples spatial and temporal zoom
Type: MATHEMATICAL
Depends on: 5

Claim 7: At zoom=0.01, the effective time compression is 1000^1.5 = 31623 ticks per displayed frame
Type: MATHEMATICAL
Depends on: 6

Claim 8: The tile server can average entity values across a time window of N frames and return one tile
Type: ARCHITECTURAL
Depends on: 1

Claim 9: Time-averaged tiles reveal migration paths and population waves not visible in single frames
Type: EMPIRICAL
Depends on: 8

Claim 10: The viewer computes t_start and t_end locally and the server is stateless
Type: ARCHITECTURAL
Depends on: 5, 6, 8

Claim 11: At 1 billion cells, tile request latency is under 100ms including disk read and downsample
Type: EMPIRICAL
Depends on: 1, 2, 3

Claim 12: At 1 trillion cells, the same tile server handles playback with identical viewer code
Type: ARCHITECTURAL
Depends on: 1, 2, 11

Claim 13: Checkpointing every N ticks enables resume after crash without losing simulation progress
Type: ARCHITECTURAL
Depends on: None

Claim 14: The recording format (individual frame_NNNNNN.bin files + meta.json) scales to 60+ frames at 1B
Type: EMPIRICAL
Depends on: 1, 13

Claim 15: Spacetime tiling is the correct generalization — spatial tiling and temporal tiling are special cases
Type: CONCEPTUAL
Depends on: 2, 6, 8

Claim 16: Frame averaging for temporal compression preserves entity type information without blurring
Type: MATHEMATICAL
Depends on: 8

Claim 17: The GPU simulation is nearly as fast as decompressing pre-recorded frames, making re-simulation a viable playback strategy
Type: EMPIRICAL
Depends on: None

Claim 18: Keyframe + re-simulate is more storage-efficient than storing every frame
Type: ARCHITECTURAL
Depends on: 13, 17
