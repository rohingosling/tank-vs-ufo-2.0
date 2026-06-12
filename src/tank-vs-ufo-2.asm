//********************************************************************************
// Program: Tank vs UFO (Commodore VIC-20) - Assembly re-write
// Version: 2.0 (As in, Duane Later's original is version 1.0)
// Date:    2021-03-06
// Author:  Rohin Gosling
//
// Description:
//
//   Kick Assembler rewrite of the 1981 BASIC type-in program "Tank-v-UFO"
//   by Duane Later, from the Commodore VIC-20 User's Manual. This version will 
//   still run on a stock unexpanded VIC-20, targeting PAL pacing.
//
//   If you're using VICE, run the game with, 'xvic -memory none'.
//
//   The rewrite preserves the original game's gameplay mechanics, including 
//   one strafing UFO at a time dropping aimed bombs, and endless play with a 
//   UFOS/TANKS kill tally. There were slight variations between the 1981 and
//   1983 editions of the original type-in program, but none of them have a 
//   win condition. So as tempting as it was to add a win condition, I resisted 
//   the urge to preserve the original's endless play and score chase.
//
//   While the idea with this project was simply to create a faithful assembly 
//   rewrite of the original, I took the liberty of improving the feel and pace
//   of game play, by making all game events non-blocking and adding some basic
//   animation where it would make sense in a an update the removes blocking 
//   events.
//
//   1. Non-blocking events. The original ran every explosion, crash dive and
//      fire as a blocking BASIC subroutine, freezing the whole game. Here
//      every entity is a state machine stepped from a single 60 Hz frame
//      loop: the tank stays under player control while a UFO explodes, UFOs
//      keep strafing while the tank burns, and a bullet-vs-bomb intercept
//      never pauses play.
//
//   2. While the tank is burning, UFOs keep flying but drop no bombs until
//      the new tank spawns.
//
//   3. Tank bullets only collide with a UFO that is still flying. Exploding
//      and crash-diving UFOs ignore bullets.
//
//   4. A hit UFO begins its diagonal crash dive immediately; the air
//      explosion animates independently at the point of bullet contact
//      (the original held everything while the blast played out).
//
//   5. Animated effects, 150 ms (9 jiffies) per frame:
//
//      - Air explosion, 3 frames graded by heat: red centre cell; yellow
//        centre with red arms; yellow arms with a transparent centre.
//      - Ground puff (a bomb missing the tank), 3 frames, black: "\|/"
//        splash; spaced dust dots over the splash; dots only.
//      - Burning tank / crashed UFO fire: the original's two flame glyphs
//        alternate; the burning tank's fire is heat-graded (red flame tips
//        on the gun row, yellow solid base on the hull row).
//
//   6. Colour changes: fire purple -> red (with the yellow gradings above);
//      score text yellow -> blue; tank yellow -> blue; air explosion
//      black -> red/yellow; muzzle flash purple -> yellow.
//
//   7. The lowest UFO strafing altitude is raised by one character row
//      (flight rows 4-16 instead of 4-17).
//
//   8. Symmetric tank travel: the column clamp is 0..16 (footprint 0..5 to
//      16..21), where the original clamped at 15 and left the rightmost
//      column unreachable.
//
//   9. Q quits at any time: a stub copied to the cassette buffer wipes the
//      game's RAM ($1000-$1FFF, zero page, stack, $0200 page) and jumps
//      through the hardware reset vector to a BASIC cold start.
//
//  10. Event durations retuned (the original's were side effects of BASIC
//      delay loops): tank burn 1.0 s, crashed-UFO ground fire 1.0 s, shot
//      noise fade 0.5 s, air explosion 3 x 150 ms; each sound fade spans
//      its event exactly.
//
//  11. Cosmetics: title line "*  TANK VS UFO  2.0  *"; the ground bar spans
//      the full 22 columns (the original PRINTed 21 -- a 22nd character on
//      the bottom row would have scrolled the screen).
//
//   Original-game quirks fixed (1981-edition bugs, not behavior):
//
//   - The score reprint no longer eats the ground line.
//   - A bullet hitting a bomb no longer destroys the tank (the original's
//     PEEK collision sent any non-space cell to the tank-hit routine); the
//     bullet and bomb now annihilate each other and play continues.
//   - Explosion / crash-dive cell writes are clamped to the screen edges
//     (the original's address arithmetic wrapped across rows).
//
// Architecture:
//
//   Each 60 Hz frame runs two phases. The update phase steps the state
//   machines: entities erase their old cells, move, collide and run their
//   timers; the main game tick (input, bullet x2, UFO flight, bomb) runs
//   every GAME_TICK_FRAMES frames to match the interpreted BASIC original's
//   speed. The draw phase (draw_all) then repaints every active entity in a
//   fixed layer order -- tank, UFO (any state), bomb, ground puff, bullet,
//   muzzle flash, tank fire, crash fire, air explosion -- so overlapping
//   entities can never permanently erase one another.
//
// Memory layout:
//
//   $1001-$100C  BASIC stub ("10 SYS 4109").
//   $100D-.....  machine code + data tables (single PRG, no overlays).
//   $1E00        screen RAM (22 x 23), $9600 colour RAM.
//   $033C        cassette buffer: hosts the Q-quit wipe stub at runtime.
//
// Timing:
//
//   The KERNAL IRQ is left running: it supplies the jiffy clock ($A2, 60 Hz
//   on PAL and NTSC) used as the frame timebase, and the current-key code at
//   $C5 used for input (exactly like the original's PEEK(197)).
//
//********************************************************************************

                .encoding "screencode_mixed"

//================================================================================
// Constants
//================================================================================

                .const BASIC_START          = $1001
                .const ML_ENTRY             = $100D

                .const SCREEN_RAM           = $1E00
                .const COLOUR_RAM           = $9600
                .const COLOUR_PAGE_OFFSET   = $78       // Colour RAM = screen RAM + $7800.

                .const VIC_BORDER_BG        = $900F     // Bits 0-2 border, bit 3 reverse, bits 4-7 bg.
                .const VIC_VOICE_1          = $900A
                .const VIC_VOICE_2          = $900B
                .const VIC_VOICE_3          = $900C     // Soprano voice (crash-dive warble).
                .const VIC_VOICE_NOISE      = $900D     // Noise voice (shot / explosions / fire).
                .const VIC_VOLUME           = $900E     // Bits 0-3 volume, bits 4-7 aux colour.
                .const VIA2_TIMER_1_LOW     = $9124     // Free-running KERNAL IRQ timer (entropy).

                .const KERNAL_JIFFY_LOW     = $A2       // 60 Hz jiffy clock, low byte.
                .const KERNAL_CURRENT_KEY   = $C5       // Matrix code of key held now (64 = none).
                .const SHIFT_MODE_LOCK      = $0291     // $80 disables SHIFT+C= charset switching.

                .const KEY_NONE             = 64
                .const KEY_Z                = 33        // Move left.
                .const KEY_C                = 34        // Move right.
                .const KEY_B                = 35        // Fire.
                .const KEY_Q                = 48        // Quit: wipe RAM and reset to BASIC.

                .const QUIT_STUB_RAM        = $033C     // Cassette buffer hosts the quit wipe stub.

                //----------------------------------------------------------------
                // Colour palette (VIC-I character colours 0-7).
                //----------------------------------------------------------------

                .const COLOUR_BLACK         = $00
                .const COLOUR_WHITE         = $01
                .const COLOUR_RED           = $02
                .const COLOUR_CYAN          = $03
                .const COLOUR_PURPLE        = $04
                .const COLOUR_GREEN         = $05
                .const COLOUR_BLUE          = $06
                .const COLOUR_YELLOW        = $07

                .const BORDER_BG_VALUE      = 25        // White background, white border (original POKE 36879,25).

                .const TANK_COLOUR          = COLOUR_BLUE
                .const SCORE_COLOUR         = COLOUR_BLUE
                .const FIRE_COLOUR          = COLOUR_RED
                .const FIRE_HOT_COLOUR      = COLOUR_YELLOW  // Burning-tank fire base (hotter than the tips).
                .const BLAST_COLOUR         = COLOUR_RED
                .const BLAST_CORE_COLOUR    = COLOUR_YELLOW  // Air-explosion centre (hotter than the arms).
                .const MUZZLE_COLOUR        = COLOUR_YELLOW
                .const SKY_OBJECT_COLOUR    = COLOUR_BLACK   // UFO, bullet, bomb, burst (as in the original).

                //----------------------------------------------------------------
                // Screen geometry (22 columns x 23 rows).
                //----------------------------------------------------------------

                .const SCREEN_COLUMNS       = 22
                .const SCREEN_ROWS          = 23

                .const ROW_TITLE            = 0
                .const ROW_HELP             = 1
                .const ROW_SCORE            = 2
                .const ROW_BULLET_TOP       = 3         // Bullets vanish above this row.
                .const ROW_UFO_MIN          = 4         // Highest UFO flight row.
                .const ROW_UFO_MAX          = 16        // Lowest UFO flight row (original was 17; raised one row).
                .const ROW_MUZZLE           = 18        // Muzzle flash / bullet spawn row, above the gun.
                .const ROW_TANK_GUN         = 19
                .const ROW_TANK_HULL        = 20
                .const ROW_TANK_TREADS      = 21        // Treads sit one row above the ground line.
                .const ROW_IMPACT           = 21        // Bombs burst and crashed UFOs rest at treads level.
                .const ROW_ABOVE_IMPACT     = 20        // Crash flames and ground-burst dust row.
                .const ROW_GROUND           = 22

                .const UFO_ROW_RANGE        = ROW_UFO_MAX - ROW_UFO_MIN + 1   // 13 spawn rows.
                .const UFO_COL_MAX          = 19        // Leftmost-cell limit (UFO is 3 cells wide).
                .const TANK_COL_MAX         = 16        // The 6-cell tank spans 0..5 to 16..21: symmetric
                                                        // travel (the original clamped at 15, leaving an
                                                        // unreachable column on the right).

                //----------------------------------------------------------------
                // Screen codes (default uppercase ROM character set).
                //----------------------------------------------------------------

                .const CHAR_SPACE           = $20
                .const CHAR_BULLET          = $2E       // "." (POKE 46 in the original).
                .const CHAR_BOMB            = $51       // Filled ball (POKE 81).
                .const CHAR_UFO_LEFT        = $3C       // "<"
                .const CHAR_UFO_MID         = $2A       // "*"
                .const CHAR_UFO_RIGHT       = $3E       // ">"
                .const CHAR_SOLID           = $A0       // Reverse space (muzzle flash, blast, hull, flames).
                .const CHAR_GROUND          = $63       // CBM-T horizontal bar (ground line).
                .const CHAR_GUN             = $42       // Vertical bar gun barrel (SHIFT-B graphics glyph).
                .const CHAR_HULL_EDGE       = $64       // CBM-@ low bar (hull left/right edge).
                .const CHAR_TREAD_LEFT      = $67       // CBM-M left tread end.
                .const CHAR_TREAD_RIGHT     = $65       // CBM-G right tread end.
                .const CHAR_WHEEL           = $0F       // "o" road wheels.
                .const CHAR_FLAME_A         = $E9       // Reversed SHIFT-POUND diagonal (flame frame A).
                .const CHAR_FLAME_B         = $DF       // Reversed CBM-* diagonal (flame frame B).
                .const CHAR_BURST_LEFT      = $4D       // Diagonal "\" (ground-burst splash, POKE 77).
                .const CHAR_BURST_MID       = $42       // Vertical bar (POKE 66).
                .const CHAR_BURST_RIGHT     = $4E       // Diagonal "/" (POKE 78).

                //----------------------------------------------------------------
                // Pacing (frames are 60 Hz jiffies; constants tuned so the PAL
                // feel matches the interpreted BASIC original).
                //----------------------------------------------------------------

                .const GAME_TICK_FRAMES     = 5         // Main tick: input, bullet x2, UFO, bomb (12 Hz).
                .const DIVE_TICK_FRAMES     = 4         // Crash-dive descent step (15 Hz).
                .const BLAST_FRAME_JIFFIES  = 9         // Air-explosion animation frame hold (150 ms x 3 frames).
                .const BLAST_FADE_FRAMES    = 2         // Air-explosion volume fade step (15 x 2 = 30).
                .const PUFF_FRAME_JIFFIES   = 9         // Ground-puff animation frame hold (150 ms x 3 frames).
                .const CRASH_FIRE_FRAMES    = 60        // Crashed-UFO fire duration (1.0 s).
                .const CRASH_FADE_FRAMES    = 4         // Crashed-UFO volume fade step (15 x 4 = 60).
                .const TANK_BURN_FRAMES     = 60        // Burning-tank duration (1.0 s).
                .const BURN_FADE_FRAMES     = 4         // Burning-tank volume fade step (15 x 4 = 60).
                .const SHOT_FADE_FRAMES     = 2         // Shot-noise volume fade step (15 x 2 = 30, 0.5 s).
                .const FLAME_FLIP_FRAMES    = 8         // Flame animation frame flip rate.

                //----------------------------------------------------------------
                // Sound register values (from the original's POKEs).
                //----------------------------------------------------------------

                .const NOISE_SHOT           = 158       // POKE 36877,158 on fire.
                .const NOISE_BLAST          = 228       // POKE 36877,128+100 on UFO hit.
                .const NOISE_FIRE           = 128       // POKE 36877,128 for both fires.
                .const WARBLE_LOW           = 248       // Crash-dive voice-3 sweep range.
                .const WARBLE_HIGH          = 253

                //----------------------------------------------------------------
                // Entity states.
                //----------------------------------------------------------------

                .const TANK_ALIVE           = 0
                .const TANK_BURNING         = 1

                .const UFO_NONE             = 0
                .const UFO_FLYING           = 1
                .const UFO_DIVING           = 3         // 2 was the old blocking blast state; the air
                .const UFO_GROUND_FIRE      = 4         // explosion is now an independent animated entity.

//================================================================================
// Zero-page variables (BASIC's zero page is free: the program never returns
// to BASIC, and the KERNAL IRQ touches only $90-$FF system areas).
//================================================================================

                .label screen_pointer       = $FB       // Current row, screen RAM (16-bit).
                .label colour_pointer       = $FD       // Current row, colour RAM (16-bit).

                .label game_tick_count      = $10       // Frames until the next main game tick.
                .label jiffy_snapshot       = $11       // Last jiffy value seen by the frame loop.

                .label tank_state           = $12
                .label tank_col             = $13       // Leftmost tank column ("a" in the original, 0..15).
                .label burn_timer_low       = $14       // Burning-tank countdown, frames (16-bit).
                .label burn_timer_high      = $15

                .label bullet_active        = $16
                .label bullet_row           = $17
                .label bullet_col           = $18
                .label shot_fade_count      = $19       // Frames until the next shot-volume fade step.

                .label ufo_state            = $1A
                .label ufo_row              = $1B
                .label ufo_col              = $1C       // Leftmost of the 3 UFO cells.
                .label ufo_direction        = $1D       // $01 = right, $FF = left.
                .label blast_timer          = $1E       // Jiffies left in the current blast frame.
                .label blast_row            = $1F
                .label blast_col            = $20
                .label dive_count           = $21       // Frames until the next dive step.
                .label fire_timer           = $22       // Crashed-UFO fire countdown, frames.

                .label bomb_active          = $23
                .label bomb_row             = $24
                .label bomb_col             = $25
                .label bomb_direction       = $26       // $01 = down-right, $FF = down-left.

                .label burst_frame          = $27       // Ground puff: 0 = inactive, 1..3 = frame.
                .label burst_timer          = $28       // Jiffies left in the current puff frame.
                .label burst_col            = $29

                .label score_ufos_low       = $2A       // BCD, 4 digits per score.
                .label score_ufos_high      = $2B
                .label score_tanks_low      = $2C
                .label score_tanks_high     = $2D

                .label random_seed          = $2E
                .label flame_phase          = $2F       // Shared flame animation phase (0 / 1).
                .label flame_count          = $30       // Frames until the next flame flip.

                .label shot_volume          = $31       // Per-source envelope volumes (0 = silent).
                .label blast_volume         = $32
                .label crash_volume         = $33
                .label burn_volume          = $34
                .label blast_fade_count     = $35
                .label crash_fade_count     = $36
                .label burn_fade_count      = $37
                .label warble_value         = $38       // Crash-dive voice-3 sweep state.
                .label warble_direction     = $39

                .label print_col            = $3A       // Score-row print cursor.
                .label number_low           = $3B       // BCD number for print_number.
                .label number_high          = $3C
                .label number_started       = $3D       // Leading-zero suppression flag.
                .label temp_target          = $3E       // Bomb-drop target column.
                .label temp_value           = $3F       // Current plot colour.
                .label temp_char            = $40       // Scratch character for the painters.
                .label paint_mode           = $41       // CHAR_SPACE = erase, anything else = draw.
                .label loop_count           = $42
                .label muzzle_active        = $43       // 1 = flash visible above the gun tip.
                .label blast_frame          = $44       // Air explosion: 0 = inactive, 1..3 = frame.
                .label bullet_hold          = $45       // 1 = fired this tick; bullet waits one tick
                                                        // (the original's GOTO 170 skipped the move).

//================================================================================
// BASIC stub: 10 SYS 4109
//================================================================================

                * = BASIC_START "BASIC stub"

                .word basic_end             // Link to next BASIC line.
                .word 10                    // Line number.
                .byte $9E                   // SYS token.
                .text @"4109"               // ML_ENTRY in decimal.
                .byte 0                     // End of line.
basic_end:      .word 0                     // End of program.

//================================================================================
// Entry point and initialisation
//================================================================================

                * = ML_ENTRY "Main"

start:
                lda #BORDER_BG_VALUE
                sta VIC_BORDER_BG
                lda #$80
                sta SHIFT_MODE_LOCK

                // Silence all four voices and the volume register.

                lda #0
                sta VIC_VOICE_1
                sta VIC_VOICE_2
                sta VIC_VOICE_3
                sta VIC_VOICE_NOISE
                sta VIC_VOLUME

                // Clear the screen to spaces and the colour RAM to black.

                ldx #0
clear_loop:
                lda #CHAR_SPACE
                sta SCREEN_RAM,x
                sta SCREEN_RAM + $0100,x
                lda #COLOUR_BLACK
                sta COLOUR_RAM,x
                sta COLOUR_RAM + $0100,x
                inx
                bne clear_loop

                // Zero the game state explicitly (zero page is NOT cleared by
                // the PRG load, and holds BASIC leftovers at this point).

                ldx #$10
                lda #0
state_loop:
                sta $00,x
                inx
                cpx #$46
                bne state_loop

                // Seed the random generator from the free-running IRQ timer.

                lda VIA2_TIMER_1_LOW
                ora #$01
                sta random_seed

                // Static screen furniture: title, help line, ground, score.

                jsr draw_title
                jsr draw_ground
                jsr draw_score

                // Arm the frame-loop dividers (the draw phase paints the tank).

#if BOUNDSTEST
                // Test build (-define BOUNDSTEST): start the tank at its
                // right-hand clamp so edge rendering can be screenshot.
                lda #TANK_COL_MAX
                sta tank_col
#endif

                lda #GAME_TICK_FRAMES
                sta game_tick_count
                lda #FLAME_FLIP_FRAMES
                sta flame_count
                lda #WARBLE_LOW
                sta warble_value
                lda #1
                sta warble_direction
#if FLAMETEST
                // Test build (-define FLAMETEST): fabricate the burning-tank
                // plus crashed-UFO overlap at boot so the flame interaction
                // can be screenshot deterministically.
                lda #TANK_BURNING
                sta tank_state
                lda #$00
                sta burn_timer_low
                lda #$07
                sta burn_timer_high
                lda #0
                sta ufo_col
                lda #ROW_IMPACT
                sta ufo_row
                jsr ufo_landed
#endif

#if BLASTTEST
                // Test build (-define BLASTTEST): fabricate an air blast
                // (held on frame 2) and a muzzle flash at boot so their
                // colours can be screenshot.
                lda #10
                sta blast_row
                sta blast_col
                lda #2
                sta blast_frame
                lda #255
                sta blast_timer
                lda #15
                sta blast_volume
                lda #BLAST_FADE_FRAMES
                sta blast_fade_count
                lda #1
                sta muzzle_active
                lda #3
                sta bullet_col

                // Also hold a ground puff on frame 2 (dots over splash).

                lda #16
                sta burst_col
                lda #2
                sta burst_frame
                lda #255
                sta burst_timer
#endif

                lda KERNAL_JIFFY_LOW
                sta jiffy_snapshot

//================================================================================
// Frame loop (60 Hz), in two phases per frame:
//
//   1. Update: state machines erase their old cells, move, collide and run
//      their timers. Nothing is drawn here.
//   2. Draw: draw_all repaints every active entity in a fixed layer order,
//      so entities can never permanently erase one another.
//
// The main game tick (input, bullet, UFO flight, bomb) runs every
// GAME_TICK_FRAMES frames inside the update phase.
//================================================================================

main_loop:
wait_frame:
                lda KERNAL_JIFFY_LOW
                cmp jiffy_snapshot
                beq wait_frame
                sta jiffy_snapshot

                jsr dive_update
                jsr crash_fire_update
                jsr burn_update
                jsr blast_anim_update
                jsr burst_anim_update
                jsr flame_update
                jsr shot_update
                jsr sound_update

                dec game_tick_count
                bne main_draw
                lda #GAME_TICK_FRAMES
                sta game_tick_count

                jsr handle_input

                // A bullet fired this tick holds in the barrel for one tick
                // so the muzzle flash gets its moment on screen (original
                // line 135 ends in GOTO 170, skipping the move that pass).

                lda bullet_hold
                beq main_bullet_steps
                lda #0
                sta bullet_hold
                jmp main_after_bullet
main_bullet_steps:
                jsr bullet_step
                jsr bullet_step             // Two cells per tick, exactly like the original FOR H=1 TO 2.
main_after_bullet:
                jsr ufo_flight
                jsr bomb_step

main_draw:
                jsr draw_all
                jmp main_loop

//================================================================================
// Input: PEEK(197) semantics -- one key at a time, no control while burning.
//================================================================================

handle_input:

                // Q quits at any time, even while the tank is burning.

                lda KERNAL_CURRENT_KEY
                cmp #KEY_Q
                beq quit_game

                ldx tank_state
                bne handle_input_done

#if AUTOPILOT
                // Test build (-define AUTOPILOT): hold the fire key forever
                // so headless VICE runs exercise the bullet / blast / dive /
                // ground-fire pipeline without a player.
                jmp fire_bullet
#endif

                cmp #KEY_Z
                beq move_left
                cmp #KEY_C
                beq move_right
                cmp #KEY_B
                beq fire_bullet
handle_input_done:
                rts

move_left:
                lda tank_col
                beq handle_input_done
                jsr erase_tank
                dec tank_col
                rts

move_right:
                lda tank_col
                cmp #TANK_COL_MAX
                bcs handle_input_done
                jsr erase_tank
                inc tank_col
                rts

//--------------------------------------------------------------------------------
// Quit (Q): silence the VIC, copy a wipe stub into the cassette buffer, and
// run it there. The stub scrubs the game's RAM ($1000-$1FFF including the
// screen, plus zero page, stack and the $0200 page) and then jumps through
// the hardware reset vector for a full cold start back to BASIC.
//--------------------------------------------------------------------------------

quit_game:
                sei
                lda #0
                sta VIC_VOLUME
                sta VIC_VOICE_3
                sta VIC_VOICE_NOISE

                ldx #quit_stub_end - quit_stub - 1
quit_copy:
                lda quit_stub,x
                sta QUIT_STUB_RAM,x
                dex
                bpl quit_copy
                jmp QUIT_STUB_RAM

quit_stub:
                .pseudopc QUIT_STUB_RAM
                {

                // Wipe $1000-$1FFF: program, data, and screen RAM.

                lda #$00
                sta $FB
                lda #$10
                sta $FC
                ldy #0
                tya
quit_wipe_block:
                sta ($FB),y
                iny
                bne quit_wipe_block
                inc $FC
                ldx $FC
                cpx #$20
                bne quit_wipe_block

                // Wipe zero page, the stack, and the $0200 page (the reset
                // re-initialises all of them; this just leaves no remnants).

                ldx #0
quit_wipe_low:
                sta $0000,x
                sta $0100,x
                sta $0200,x
                inx
                bne quit_wipe_low

                jmp ($FFFC)             // Hardware reset vector: cold start.
                }
quit_stub_end:

fire_bullet:
                lda bullet_active
                bne handle_input_done

                inc bullet_active
                lda #ROW_MUZZLE
                sta bullet_row
                lda tank_col
                clc
                adc #3
                sta bullet_col

                // Muzzle flash: lives one row above the gun tip (the bullet's
                // spawn cell, like the original's POKE 8079+A) until the
                // bullet's first step. Drawn by the draw phase while active.

                lda #1
                sta muzzle_active
                sta bullet_hold

                // Shot sound: noise voice, volume 15 fading over 0.5 s.

                lda #15
                sta shot_volume
                lda #SHOT_FADE_FRAMES
                sta shot_fade_count
                rts

//================================================================================
// Bullet: one cell up per call; erases its old cell (the muzzle flash on the
// first step) and checks UFO and bomb collisions. Drawing happens in the
// draw phase.
//================================================================================

bullet_step:
                lda bullet_active
                bne bullet_alive
                rts
bullet_alive:
                lda #0
                sta muzzle_active           // The flash dies with the first step.
                ldx bullet_row
                ldy bullet_col
                jsr erase_cell
                dec bullet_row
                lda bullet_row
                cmp #ROW_BULLET_TOP
                bcs bullet_check_ufo

                // Off the top of the play field (original: C < 7746).

                lda #0
                sta bullet_active
                rts

bullet_check_ufo:

                // Bullets only hit a UFO that is still flying (difference 3).

                lda ufo_state
                cmp #UFO_FLYING
                bne bullet_check_bomb
                lda bullet_row
                cmp ufo_row
                bne bullet_check_bomb
                lda bullet_col
                sec
                sbc ufo_col
                cmp #3
                bcc bullet_hits_ufo

bullet_check_bomb:

                // Bullet-vs-bomb intercept: both vanish, play continues
                // (the original sent this to the tank-destroyed routine).

                lda bomb_active
                beq bullet_draw
                lda bullet_row
                cmp bomb_row
                bne bullet_draw
                lda bullet_col
                cmp bomb_col
                bne bullet_draw

                lda #0
                sta bullet_active
                sta bomb_active
                ldx bomb_row
                ldy bomb_col
                jmp erase_cell

bullet_draw:
                rts                         // Drawing happens in the draw phase.

//--------------------------------------------------------------------------------
// Bullet hit: the UFO begins its crash dive IMMEDIATELY, while the air
// explosion animates independently at the point of contact.
//--------------------------------------------------------------------------------

bullet_hits_ufo:
                lda #0
                sta bullet_active
                sta shot_volume             // Original line 601: L = 0.

                lda #UFO_DIVING
                sta ufo_state
                lda #DIVE_TICK_FRAMES
                sta dive_count

                lda bullet_row
                sta blast_row
                lda bullet_col
                sta blast_col
                lda #1
                sta blast_frame
                lda #BLAST_FRAME_JIFFIES
                sta blast_timer
                lda #15
                sta blast_volume
                lda #BLAST_FADE_FRAMES
                sta blast_fade_count
                rts

//================================================================================
// UFO flight: one cell of horizontal travel per game tick, plus the aimed
// bomb-drop check. Spawns a fresh UFO whenever the slot is empty.
//================================================================================

ufo_flight:
                lda ufo_state
                beq spawn_ufo
                cmp #UFO_FLYING
                beq ufo_fly
                rts

ufo_fly:
                jsr erase_ufo
                lda ufo_direction
                bmi ufo_fly_left

                inc ufo_col
                lda ufo_col
                cmp #UFO_COL_MAX + 1
                bcc ufo_moved
                jmp ufo_despawn

ufo_fly_left:
                lda ufo_col
                beq ufo_despawn
                dec ufo_col

ufo_moved:

                // Bomb drop: one bomb at a time, aimed to land on the tank,
                // and never while the tank is burning (difference 2).

                lda bomb_active
                bne ufo_flight_done
                lda tank_state
                bne ufo_flight_done

                lda ufo_direction
                bmi ufo_aim_left

                // Flying right: drop when right cell = tank_col + ufo_row - 17
                // (diagonal down-right meets the hull row 20 at tank_col + 3,
                // matching the original's line-182 aim).

                lda tank_col
                clc
                adc ufo_row
                sec
                sbc #17
                sta temp_target
                jmp ufo_aim_check

ufo_aim_left:

                // Flying left: drop when right cell = tank_col + 22 - ufo_row
                // (diagonal down-left meets the gun tip at row 19, tank_col + 3,
                // matching the original's line-180 aim).

                lda tank_col
                clc
                adc #22
                sec
                sbc ufo_row
                sta temp_target

ufo_aim_check:
                lda ufo_col
                clc
                adc #2
                cmp temp_target
                bne ufo_flight_done

                // Release the bomb one row below, one cell ahead of travel.

                lda #1
                sta bomb_active
                lda ufo_row
                clc
                adc #1
                sta bomb_row
                lda ufo_direction
                sta bomb_direction
                bmi ufo_drop_left

                lda ufo_col
                clc
                adc #3
                sta bomb_col
                rts

ufo_drop_left:
                lda ufo_col
                clc
                adc #1
                sta bomb_col
ufo_flight_done:
                rts

ufo_despawn:
                lda #UFO_NONE
                sta ufo_state
                rts

spawn_ufo:
                lda #UFO_FLYING
                sta ufo_state

                jsr random_mod_13
                clc
                adc #ROW_UFO_MIN
                sta ufo_row

                jsr random_byte
                and #$01
                beq spawn_from_right

                lda #$01
                sta ufo_direction
                lda #0
                sta ufo_col
                rts

spawn_from_right:
                lda #$FF
                sta ufo_direction
                lda #UFO_COL_MAX
                sta ufo_col
                rts

//================================================================================
// Bomb: one diagonal cell per game tick. Checks the tank silhouette, the
// ground, and the bullet -- in that order, like the original PEEK chain.
//================================================================================

bomb_step:
                lda bomb_active
                bne bomb_alive
                rts
bomb_alive:
                ldx bomb_row
                ldy bomb_col
                jsr erase_cell

                inc bomb_row
                lda bomb_col
                clc
                adc bomb_direction
                sta bomb_col

                // Tank collision (only while the tank is alive).

                lda tank_state
                bne bomb_check_ground
                lda bomb_row
                cmp #ROW_TANK_GUN
                bcc bomb_check_ground

                // Rows 19..21: gun, hull, treads (a bomb cannot pass row 21).

                cmp #ROW_TANK_GUN
                beq bomb_row_gun
                cmp #ROW_TANK_HULL
                beq bomb_row_hull

                // Treads row: tank_col .. tank_col + 5.

                lda bomb_col
                sec
                sbc tank_col
                cmp #6
                bcc bomb_tank_hit
                jmp bomb_check_ground

bomb_tank_hit:
                jmp tank_hit

bomb_row_gun:

                // Gun row: only the barrel cell at tank_col + 3.

                lda tank_col
                clc
                adc #3
                cmp bomb_col
                beq bomb_tank_hit
                jmp bomb_check_ground

bomb_row_hull:

                // Hull row: tank_col + 1 .. tank_col + 4.

                lda bomb_col
                sec
                sbc tank_col
                sec
                sbc #1
                cmp #4
                bcc bomb_tank_hit

bomb_check_ground:
                lda bomb_row
                cmp #ROW_IMPACT
                bcs ground_burst

                // Bullet intercept (same outcome as the bullet-side check).

                lda bullet_active
                beq bomb_draw
                lda bomb_row
                cmp bullet_row
                bne bomb_draw
                lda bomb_col
                cmp bullet_col
                bne bomb_draw

                lda #0
                sta bullet_active
                sta bomb_active
                ldx bomb_row
                ldy bomb_col
                jmp erase_cell

bomb_draw:
                rts                         // Drawing happens in the draw phase.

//--------------------------------------------------------------------------------
// Ground puff: a bomb that misses bursts where it lands. Three animated
// frames, 150 ms each, all black. The dust dots sit one blank cell apart,
// spanning five columns (burst_col - 2 .. burst_col + 2):
//
//   frame 1:   (nothing)     frame 2:   . . .     frame 3:   . . .
//               \|/                      \|/                 (nothing)
//--------------------------------------------------------------------------------

ground_burst:
                lda #0
                sta bomb_active
                lda #1
                sta burst_frame
                lda #PUFF_FRAME_JIFFIES
                sta burst_timer
                lda bomb_col
                sta burst_col
                rts

burst_anim_update:
                lda burst_frame
                bne burst_running
                rts
burst_running:
                dec burst_timer
                bne burst_anim_done
                jsr erase_puff
                inc burst_frame
                lda burst_frame
                cmp #4
                bcc burst_rearm
                lda #0
                sta burst_frame
                rts
burst_rearm:
                lda #PUFF_FRAME_JIFFIES
                sta burst_timer
burst_anim_done:
                rts

// Draw the current puff frame (draw phase). The splash row shows on frames
// 1-2; the dust dots show on frames 2-3.

draw_puff:
                lda burst_frame
                cmp #3
                bcs draw_puff_dots

                ldx #ROW_IMPACT
                ldy burst_col
                lda #CHAR_BURST_MID
                jsr plot_black_clamped
                ldy burst_col
                dey
                lda #CHAR_BURST_LEFT
                jsr plot_black_clamped
                ldy burst_col
                iny
                lda #CHAR_BURST_RIGHT
                jsr plot_black_clamped

draw_puff_dots:
                lda burst_frame
                cmp #2
                bcc draw_puff_done

                ldx #ROW_ABOVE_IMPACT
                ldy burst_col
                dey
                dey
                lda #3
                sta loop_count
draw_puff_dot_loop:
                lda #CHAR_BULLET            // "." dust, same glyph as the original.
                jsr plot_black_clamped
                iny                         // Two cells per step: a blank cell
                iny                         // separates each pair of dots.
                dec loop_count
                bne draw_puff_dot_loop
draw_puff_done:
                rts

// Erase the puff's full footprint, edge-clamped: the 3-cell splash row plus
// the three spaced dust dots above it (5 columns, every second cell).

erase_puff:
                ldx #ROW_IMPACT             // Splash row: 3 contiguous cells.
                ldy burst_col
                dey
                lda #3
                sta loop_count
erase_splash_cell:
                lda #CHAR_SPACE
                jsr plot_black_clamped
                iny
                dec loop_count
                bne erase_splash_cell

                ldx #ROW_ABOVE_IMPACT       // Dust row: 3 dots, 2 cells apart.
                ldy burst_col
                dey
                dey
                lda #3
                sta loop_count
erase_dust_cell:
                lda #CHAR_SPACE
                jsr plot_black_clamped
                iny
                iny
                dec loop_count
                bne erase_dust_cell
                rts

// Plot A at row X / column Y in black, skipping columns outside 0..21.
// Preserves X and Y.

plot_black_clamped:
                cpy #SCREEN_COLUMNS
                bcs plot_black_skip
                sta temp_char
                lda #SKY_OBJECT_COLOUR
                sta temp_value
                lda temp_char
                jsr plot_cell
plot_black_skip:
                rts

//================================================================================
// Tank hit: enter the burning state. UFOs keep strafing (non-blocking) but
// hold their bombs until the new tank spawns.
//================================================================================

tank_hit:
                lda #0
                sta bomb_active
                sta shot_volume             // Original line 700: L = 0.
                lda #TANK_BURNING
                sta tank_state
                lda #<TANK_BURN_FRAMES
                sta burn_timer_low
                lda #>TANK_BURN_FRAMES
                sta burn_timer_high
                lda #15
                sta burn_volume
                lda #BURN_FADE_FRAMES
                sta burn_fade_count

                // The flame cells cover the gun and hull rows; erase the tank
                // body once so no stray gun/hull glyph outlives the hit (the
                // draw phase repaints treads + flames every frame).

                jmp erase_tank

burn_update:
                lda tank_state
                bne burn_running
                rts
burn_running:
                lda burn_timer_low
                bne burn_decrement
                dec burn_timer_high
burn_decrement:
                dec burn_timer_low
                lda burn_timer_low
                ora burn_timer_high
                bne burn_fade

                // Burn finished: clear the wreck, score the loss, respawn at
                // the left edge exactly like the original (A = 0).

                jsr erase_tank
                lda #0
                sta burn_volume
                sta tank_state
                sta tank_col

                sed
                clc
                lda score_tanks_low
                adc #1
                sta score_tanks_low
                lda score_tanks_high
                adc #0
                sta score_tanks_high
                cld

                jmp draw_score              // The draw phase repaints the new tank.

burn_fade:
                dec burn_fade_count
                bne burn_update_done
                lda #BURN_FADE_FRAMES
                sta burn_fade_count
                lda burn_volume
                beq burn_update_done
                dec burn_volume
burn_update_done:
                rts

//================================================================================
// Air blast: an independent three-frame animation (150 ms per frame) fixed
// at the bullet's point of contact, graded by heat:
//
//   frame 1:    .          frame 2:    X          frame 3:    Y
//              .X.                    XYX                    Y.Y
//               .                      X                      Y
//
//   (X = red solid, Y = yellow solid, . = transparent)
//================================================================================

blast_anim_update:

                // Volume fade runs independently of the animation frames.

                lda blast_volume
                beq blast_anim
                dec blast_fade_count
                bne blast_anim
                lda #BLAST_FADE_FRAMES
                sta blast_fade_count
                dec blast_volume

blast_anim:
                lda blast_frame
                bne blast_anim_running
                rts
blast_anim_running:
                dec blast_timer
                bne blast_anim_done
                jsr erase_blast_cells
                inc blast_frame
                lda blast_frame
                cmp #4
                bcc blast_rearm
                lda #0
                sta blast_frame
                rts
blast_rearm:
                lda #BLAST_FRAME_JIFFIES
                sta blast_timer
blast_anim_done:
                rts

// Draw the current blast frame (draw phase).

draw_blast_frame:
                lda blast_frame
                cmp #2
                beq draw_blast_2
                bcs draw_blast_3

                // Frame 1: a single red solid cell at the centre.

                lda #BLAST_COLOUR
                sta temp_value
                ldx blast_row
                ldy blast_col
                lda #CHAR_SOLID
                jmp plot_cell

draw_blast_2:

                // Frame 2: yellow centre, red arms.

                lda #BLAST_CORE_COLOUR
                sta temp_value
                ldx blast_row
                ldy blast_col
                lda #CHAR_SOLID
                jsr plot_cell
                lda #BLAST_COLOUR
                sta temp_value
                jmp draw_blast_arms

draw_blast_3:

                // Frame 3: yellow arms, transparent centre.

                lda #BLAST_CORE_COLOUR
                sta temp_value

// Plot the four arm cells (up, down, left, right) of the blast in the
// colour already in temp_value, clamping the side cells at the edges.

draw_blast_arms:
                ldx blast_row
                dex
                ldy blast_col
                lda #CHAR_SOLID
                jsr plot_cell
                ldx blast_row
                inx
                lda #CHAR_SOLID
                jsr plot_cell
                ldx blast_row
                ldy blast_col
                beq draw_blast_arm_right    // Skip the left cell at column 0.
                dey
                lda #CHAR_SOLID
                jsr plot_cell
draw_blast_arm_right:
                ldy blast_col
                iny
                cpy #SCREEN_COLUMNS
                bcs draw_blast_arms_done
                lda #CHAR_SOLID
                jsr plot_cell
draw_blast_arms_done:
                rts

// Erase the blast's full plus-shaped footprint (all five cells), clamped.

erase_blast_cells:
                ldx blast_row
                ldy blast_col
                jsr erase_cell
                dex
                jsr erase_cell
                inx
                inx
                jsr erase_cell
                ldx blast_row
                ldy blast_col
                beq erase_blast_right
                dey
                jsr erase_cell
erase_blast_right:
                ldy blast_col
                iny
                cpy #SCREEN_COLUMNS
                bcs erase_blast_done
                jsr erase_cell
erase_blast_done:
                rts

//================================================================================
// Crash dive: the stricken UFO falls one row per step, drifting with its
// direction of travel, until it lands on the impact row and catches fire.
//================================================================================

dive_update:
                lda ufo_state
                cmp #UFO_DIVING
                beq dive_running
                rts
dive_running:
                dec dive_count
                beq dive_step
                rts

dive_step:
                lda #DIVE_TICK_FRAMES
                sta dive_count

                jsr erase_ufo               // The draw phase repaints anything clipped.

dive_descend:
                inc ufo_row

                // Sideways drift, clamped at the edges (the original's address
                // arithmetic wrapped across rows here -- quirk fixed).

                lda ufo_direction
                bmi dive_drift_left
                lda ufo_col
                cmp #UFO_COL_MAX
                bcs dive_check_landing
                inc ufo_col
                jmp dive_check_landing
dive_drift_left:
                lda ufo_col
                beq dive_check_landing
                dec ufo_col

dive_check_landing:
                lda ufo_row
                cmp #ROW_IMPACT
                bcs ufo_landed
                rts

ufo_landed:

                // Wreck rests on the impact row with flames on the row above
                // (both drawn by the draw phase from here on).

                lda #UFO_GROUND_FIRE
                sta ufo_state
                lda #CRASH_FIRE_FRAMES
                sta fire_timer
                lda #15
                sta crash_volume
                lda #CRASH_FADE_FRAMES
                sta crash_fade_count
                rts

crash_fire_update:
                lda ufo_state
                cmp #UFO_GROUND_FIRE
                beq crash_fire_running
                rts
crash_fire_running:
                dec fire_timer
                beq crash_fire_finished

                dec crash_fade_count
                bne crash_fire_done
                lda #CRASH_FADE_FRAMES
                sta crash_fade_count
                lda crash_volume
                beq crash_fire_done
                dec crash_volume
crash_fire_done:
                rts

crash_fire_finished:

                // Clear the flames and the wreck, bank the kill, free the slot.

                ldx #ROW_ABOVE_IMPACT
                jsr set_row_pointer
                ldy ufo_col
                lda #CHAR_SPACE
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                ldx #ROW_IMPACT
                jsr set_row_pointer
                ldy ufo_col
                lda #CHAR_SPACE
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y

                lda #0
                sta crash_volume
                sta ufo_state

                sed
                clc
                lda score_ufos_low
                adc #1
                sta score_ufos_low
                lda score_ufos_high
                adc #0
                sta score_ufos_high
                cld

                jmp draw_score              // The draw phase repaints any overlap.

//================================================================================
// Flame animation: one shared phase flips the burning-tank and crashed-UFO
// flame glyphs between the original's two frames. The draw phase reads the
// phase every frame; this just advances it.
//================================================================================

flame_update:
                dec flame_count
                beq flame_flip
                rts
flame_flip:
                lda #FLAME_FLIP_FRAMES
                sta flame_count
                lda flame_phase
                eor #$01
                sta flame_phase
                rts

// Burning tank: flame glyphs over the gun row, solid fire over the hull row,
// four cells wide over the hull (cols tank_col+1..+4) -- the original's
// line 701 does A=A+1 before its TAB(A) reverse-print pattern. The base of
// the fire burns hotter (yellow) than the flame tips above it (red).

draw_tank_flames:
                lda #FIRE_COLOUR
                sta temp_value
                ldx #ROW_TANK_GUN
                jsr set_row_pointer
                jsr flame_char
                ldy tank_col
                iny
                jsr plot_four
                ldx #ROW_TANK_HULL
                jsr set_row_pointer
                lda #FIRE_HOT_COLOUR
                sta temp_value
                lda #CHAR_SOLID
                ldy tank_col
                iny
                jmp plot_four

// Crashed UFO: three flame cells on the treads row, above the wreck.

draw_crash_flames:
                lda #FIRE_COLOUR
                sta temp_value
                ldx #ROW_ABOVE_IMPACT
                jsr set_row_pointer
                jsr flame_char
                ldy ufo_col
                jsr plot_run_3
                rts

// A = current flame glyph for the shared phase.

flame_char:
                lda flame_phase
                beq flame_char_a
                lda #CHAR_FLAME_B
                rts
flame_char_a:
                lda #CHAR_FLAME_A
                rts

// Plot A at (row pointer), columns Y .. Y+3, colour temp_value.

plot_four:
                jsr plot_run_3
                iny
                sta (screen_pointer),y
                pha
                lda temp_value
                sta (colour_pointer),y
                pla
                rts

// Plot A at (row pointer), columns Y .. Y+2, colour temp_value.

plot_run_3:
                sta (screen_pointer),y
                pha
                lda temp_value
                sta (colour_pointer),y
                pla
                iny
                sta (screen_pointer),y
                pha
                lda temp_value
                sta (colour_pointer),y
                pla
                iny
                sta (screen_pointer),y
                pha
                lda temp_value
                sta (colour_pointer),y
                pla
                rts

//================================================================================
// Draw phase: repaint every active entity once per frame, in a fixed layer
// order (later entries draw on top):
//
//   0. tank (alive: full body; burning: treads only)
//   1. UFO (flying / diving / crashed wreck)
//   2. bomb
//   3. ground puff
//   4. bullet
//   5. muzzle flash
//   6. tank fire
//   7. UFO crash fire
//   8. air explosion
//================================================================================

draw_all:
                lda tank_state
                bne draw_all_burning
                jsr draw_tank
                jmp draw_all_ufo
draw_all_burning:
                jsr draw_tank_treads

draw_all_ufo:
                lda ufo_state
                beq draw_all_bomb
                cmp #UFO_GROUND_FIRE
                beq draw_all_wreck
                jsr draw_ufo
                jmp draw_all_bomb
draw_all_wreck:
                jsr draw_wreck

draw_all_bomb:
                lda bomb_active
                beq draw_all_puff
                jsr draw_bomb

draw_all_puff:
                lda burst_frame
                beq draw_all_bullet
                jsr draw_puff

draw_all_bullet:
                lda bullet_active
                beq draw_all_muzzle
                jsr draw_bullet

draw_all_muzzle:
                lda muzzle_active
                beq draw_all_tank_fire
                jsr draw_muzzle

draw_all_tank_fire:
                lda tank_state
                beq draw_all_crash_fire
                jsr draw_tank_flames

draw_all_crash_fire:
                lda ufo_state
                cmp #UFO_GROUND_FIRE
                bne draw_all_blast
                jsr draw_crash_flames

draw_all_blast:
                lda blast_frame
                beq draw_all_done
                jsr draw_blast_frame
draw_all_done:
                rts

// Crashed UFO wreck on the impact row, black like the original.

draw_wreck:
                lda #SKY_OBJECT_COLOUR
                sta temp_value
                ldx #ROW_IMPACT
                jsr set_row_pointer
                ldy ufo_col
                lda #CHAR_UFO_LEFT
                jsr plot_at_y
                iny
                lda #CHAR_UFO_MID
                jsr plot_at_y
                iny
                lda #CHAR_UFO_RIGHT
                jmp plot_at_y

draw_bomb:
                lda #SKY_OBJECT_COLOUR
                sta temp_value
                ldx bomb_row
                ldy bomb_col
                lda #CHAR_BOMB
                jmp plot_cell

draw_bullet:
                lda #SKY_OBJECT_COLOUR
                sta temp_value
                ldx bullet_row
                ldy bullet_col
                lda #CHAR_BULLET
                jmp plot_cell

draw_muzzle:
                lda #MUZZLE_COLOUR
                sta temp_value
                ldx #ROW_MUZZLE
                ldy bullet_col
                lda #CHAR_SOLID
                jmp plot_cell

//================================================================================
// Sound: one mixer pass per frame. The noise voice carries the loudest
// active source (blast > fires > shot); voice 3 warbles during the dive.
//================================================================================

// Shot-noise envelope: one volume step every SHOT_FADE_FRAMES frames.

shot_update:
                lda shot_volume
                beq shot_update_done
                dec shot_fade_count
                bne shot_update_done
                lda #SHOT_FADE_FRAMES
                sta shot_fade_count
                dec shot_volume
shot_update_done:
                rts

sound_update:

                // Noise-voice value by source priority.

                lda blast_volume
                beq sound_try_burn
                lda #NOISE_BLAST
                jmp sound_set_noise
sound_try_burn:
                lda burn_volume
                ora crash_volume
                beq sound_try_shot
                lda #NOISE_FIRE
                jmp sound_set_noise
sound_try_shot:
                lda shot_volume
                beq sound_noise_off
                lda #NOISE_SHOT
                jmp sound_set_noise
sound_noise_off:
                lda #0
sound_set_noise:
                sta VIC_VOICE_NOISE

                // Crash-dive warble on voice 3 (sweep 248..253 and back).

                lda ufo_state
                cmp #UFO_DIVING
                bne sound_warble_off

                lda warble_value
                clc
                adc warble_direction
                cmp #WARBLE_HIGH
                bcc sound_warble_low_check
                lda #$FF
                sta warble_direction
                lda #WARBLE_HIGH
sound_warble_low_check:
                cmp #WARBLE_LOW
                bcs sound_warble_store
                lda #$01
                sta warble_direction
                lda #WARBLE_LOW
sound_warble_store:
                sta warble_value
                sta VIC_VOICE_3
                jmp sound_volume

sound_warble_off:
                lda #0
                sta VIC_VOICE_3

sound_volume:

                // Master volume = loudest active envelope; the dive plays at
                // full volume (original line 640: POKE VA,15).

                lda #0
                ldx ufo_state
                cpx #UFO_DIVING
                bne sound_volume_max
                lda #15
sound_volume_max:
                cmp shot_volume
                bcs sound_volume_blast
                lda shot_volume
sound_volume_blast:
                cmp blast_volume
                bcs sound_volume_crash
                lda blast_volume
sound_volume_crash:
                cmp crash_volume
                bcs sound_volume_burn
                lda crash_volume
sound_volume_burn:
                cmp burn_volume
                bcs sound_volume_store
                lda burn_volume
sound_volume_store:
                sta VIC_VOLUME
                rts

//================================================================================
// Drawing helpers
//================================================================================

// Set screen_pointer / colour_pointer to the start of row X. Preserves X, Y.

set_row_pointer:
                lda screen_row_low,x
                sta screen_pointer
                sta colour_pointer
                lda screen_row_high,x
                sta screen_pointer + 1
                clc
                adc #COLOUR_PAGE_OFFSET
                sta colour_pointer + 1
                rts

// Plot character A at row X, column Y, colour temp_value. Preserves X, Y.

plot_cell:
                pha
                jsr set_row_pointer
                pla
                sta (screen_pointer),y
                pha
                lda temp_value
                sta (colour_pointer),y
                pla
                rts

// Erase (space) the cell at row X, column Y. Preserves X, Y.

erase_cell:
                jsr set_row_pointer
                lda #CHAR_SPACE
                sta (screen_pointer),y
                rts

//--------------------------------------------------------------------------------
// Tank: the original three-row PRINT shape, drawn in blue (difference 5).
//
//   row 19:     |          (gun barrel at tank_col + 3)
//   row 20:    _##_         (hull: low bars and solid blocks)
//   row 21:   |oooo|        (treads, one row above the ground line)
//--------------------------------------------------------------------------------

draw_tank:
                lda #TANK_COLOUR
                sta temp_value

                ldx #ROW_TANK_GUN
                jsr set_row_pointer
                ldy tank_col
                iny
                iny
                iny
                lda #CHAR_GUN
                sta (screen_pointer),y
                lda temp_value
                sta (colour_pointer),y

                ldx #ROW_TANK_HULL
                jsr set_row_pointer
                ldy tank_col
                iny
                lda #CHAR_HULL_EDGE
                jsr plot_at_y
                iny
                lda #CHAR_SOLID
                jsr plot_at_y
                iny
                lda #CHAR_SOLID
                jsr plot_at_y
                iny
                lda #CHAR_HULL_EDGE
                jsr plot_at_y

// The treads row alone -- also drawn while the tank burns (the original
// kept the treads visible under the flames).

draw_tank_treads:
                lda #TANK_COLOUR
                sta temp_value
                ldx #ROW_TANK_TREADS
                jsr set_row_pointer
                ldy tank_col
                lda #CHAR_TREAD_LEFT
                jsr plot_at_y
                iny
                lda #CHAR_WHEEL
                jsr plot_at_y
                iny
                lda #CHAR_WHEEL
                jsr plot_at_y
                iny
                lda #CHAR_WHEEL
                jsr plot_at_y
                iny
                lda #CHAR_WHEEL
                jsr plot_at_y
                iny
                lda #CHAR_TREAD_RIGHT
                jmp plot_at_y

// Plot A at column Y of the current row pointer, colour temp_value.

plot_at_y:
                sta (screen_pointer),y
                lda temp_value
                sta (colour_pointer),y
                rts

// Erase the full 6 x 3 tank footprint at tank_col.

erase_tank:
                ldx #ROW_TANK_GUN
erase_tank_row:
                jsr set_row_pointer
                ldy tank_col
                lda #CHAR_SPACE
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                inx
                cpx #ROW_TANK_TREADS + 1
                bne erase_tank_row
                rts

//--------------------------------------------------------------------------------
// UFO: "<*>" at (ufo_row, ufo_col), black like the original.
//--------------------------------------------------------------------------------

draw_ufo:
                lda #SKY_OBJECT_COLOUR
                sta temp_value
                ldx ufo_row
                jsr set_row_pointer
                ldy ufo_col
                lda #CHAR_UFO_LEFT
                jsr plot_at_y
                iny
                lda #CHAR_UFO_MID
                jsr plot_at_y
                iny
                lda #CHAR_UFO_RIGHT
                jmp plot_at_y

erase_ufo:
                ldx ufo_row
                jsr set_row_pointer
                ldy ufo_col
                lda #CHAR_SPACE
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                iny
                sta (screen_pointer),y
                rts

//--------------------------------------------------------------------------------
// Static furniture: title, help line, and the ground bar.
//--------------------------------------------------------------------------------

draw_title:
                lda #COLOUR_BLACK
                sta temp_value
                ldx #ROW_TITLE
                jsr set_row_pointer
                ldy #0
draw_title_loop:
                lda title_text,y
                jsr plot_at_y
                iny
                cpy #SCREEN_COLUMNS         // The title is the full 22 columns wide.
                bne draw_title_loop

                ldx #ROW_HELP
                jsr set_row_pointer
                ldy #0
draw_help_loop:
                lda help_text,y
                jsr plot_at_y
                iny
                cpy #21
                bne draw_help_loop
                rts

// Full 22-column ground bar. The original PRINTed only 21 characters --
// a 22nd would have scrolled the screen -- but POKEs have no such limit.

draw_ground:
                lda #COLOUR_BLACK
                sta temp_value
                ldx #ROW_GROUND
                jsr set_row_pointer
                ldy #0
draw_ground_loop:
                lda #CHAR_GROUND
                jsr plot_at_y
                iny
                cpy #SCREEN_COLUMNS
                bne draw_ground_loop
                rts

//--------------------------------------------------------------------------------
// Score row: "ufos N tanks N" in blue (difference 5; the original printed it
// in yellow), with BASIC's leading-space number formatting.
//--------------------------------------------------------------------------------

draw_score:
                ldx #ROW_SCORE
                jsr set_row_pointer

                // Clear the whole row first (the original cleared 16 cells).

                ldy #SCREEN_COLUMNS - 1
                lda #CHAR_SPACE
draw_score_clear:
                sta (screen_pointer),y
                dey
                bpl draw_score_clear

                lda #SCORE_COLOUR
                sta temp_value
                lda #0
                sta print_col

                ldx #0
draw_score_ufos_label:
                lda ufos_text,x
                jsr print_char
                inx
                cpx #4
                bne draw_score_ufos_label

                inc print_col               // BASIC's leading space before a number.
                lda score_ufos_low
                sta number_low
                lda score_ufos_high
                sta number_high
                jsr print_number
                inc print_col               // BASIC's trailing space after a number.

                ldx #0
draw_score_tanks_label:
                lda tanks_text,x
                jsr print_char
                inx
                cpx #5
                bne draw_score_tanks_label

                inc print_col
                lda score_tanks_low
                sta number_low
                lda score_tanks_high
                sta number_high
                jmp print_number

// Emit character A at the score-row print cursor and advance it.

print_char:
                ldy print_col
                sta (screen_pointer),y
                lda temp_value
                sta (colour_pointer),y
                inc print_col
                rts

// Print the 4-digit BCD number in number_high / number_low without leading
// zeros (a lone zero still prints).

print_number:
                lda #0
                sta number_started

                lda number_high
                lsr
                lsr
                lsr
                lsr
                jsr print_digit
                lda number_high
                and #$0F
                jsr print_digit
                lda number_low
                lsr
                lsr
                lsr
                lsr
                jsr print_digit

                lda number_low
                and #$0F
                ora #$30                    // Last digit always prints.
                jmp print_char

print_digit:
                bne print_digit_emit
                ldx number_started
                beq print_digit_skip
                lda #0
print_digit_emit:
                ora #$30
                jsr print_char
                lda #1
                sta number_started
print_digit_skip:
                rts

//================================================================================
// Random numbers: 8-bit LFSR stirred with the free-running IRQ timer.
//================================================================================

random_byte:
                lda random_seed
                asl
                bcc random_no_feedback
                eor #$1D
random_no_feedback:
                sta random_seed
                eor VIA2_TIMER_1_LOW
                rts

// Uniform 0..12 by rejection (for the 13 UFO spawn rows).

random_mod_13:
                jsr random_byte
                and #$0F
                cmp #13
                bcs random_mod_13
                rts

//================================================================================
// Data tables
//================================================================================

screen_row_low:
                .fill SCREEN_ROWS, <(SCREEN_RAM + i * SCREEN_COLUMNS)
screen_row_high:
                .fill SCREEN_ROWS, >(SCREEN_RAM + i * SCREEN_COLUMNS)

title_text:
                .text "*  tank vs ufo  2.0  *"
help_text:
                .text "z-left,c-right,b-fire"
ufos_text:
                .text "ufos"
tanks_text:
                .text "tanks"
