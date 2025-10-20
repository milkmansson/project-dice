// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import log
import gpio
import i2c
import math
import esp32
import mpu6050 show *
import encoding.tison
import tp4057

import ssd1306 show *
import pixel-display show *
import pixel-display.two-color show *

import font show *
import font-x11-adobe.sans-08
import font-x11-adobe.sans-08-bold
import font-x11-adobe.sans-24
import font-x11-adobe.sans-24-bold

import pictogrammers-icons.size-32 as icons-32
import pictogrammers-icons.size-20 as icons-20
import crypto.sha

import system.storage

/*
A Toit project for Digital Dice

See README.md
*/

/* .............PLEASE SET VARIABLES BETWEEN HERE................. */

// MOVEMENT DETECTION: Suggested values 20–40mg, for 20–50ms.
STILL-TO-MOTION-MG := 40   // force required to register motion. Bigger value = more movement required.
STILL-TO-MOTION-MS := 5    // duration of that force required to register motion. = Bigger value = movement required for longer.

// STILL DETECTION: Suggested values 5–10mg, for 600ms.
MOTION-TO-STILL-MG := 10   // forces on the device need to be less than this many milli-g's.
MOTION-TO-STILL-MS := 600  // ... for at least this duration of milliseconds.

SDA-PIN-NUMBER := 19       // please set these correctly for your device
SCL-PIN-NUMBER := 20       // please set these correctly for your device
INTERRUPT-PIN-NUMBER := 6  // please set these correctly for your device

/* ..........................AND HERE............................. */

min-roll := 1
max-roll := 10

// Globals for sharing between functions and tasks
SCREEN-REFRESH-DURATION := (Duration --ms=250)
DISTRIBUTION-REFRESH-DURATION := (Duration --ms=1000)
WAKE-DURATION := (Duration --m=2)
CHECK-DURATION := (Duration --s=10)
BATTERY-DISPLAY-REFRESH := (Duration --s=30)

logger/log.Logger := ?
distribution-map := ?
pixel-display := ?
tasks/Map := {:}
last-touch-monotonic/int := Time.monotonic-us
interrupt-pin/gpio.Pin := ?

main:
  // Prepare Logger
  logger = log.default.with-name "project-dice"

  distribution-map = {:}
  // Switch from MAP to Ram backed Bucket (for now)
  //distribution-map = storage.Bucket.open --ram "project-dice"

  // Prepare Variables
  ssd1306-device := ?
  ssd1306-driver := ?
  mpu6050-device := ?
  mpu6050-driver := ?

  // Enable and drive I2C
  frequency := 400_000
  sda-pin := gpio.Pin SDA-PIN-NUMBER
  scl-pin := gpio.Pin SCL-PIN-NUMBER
  bus := i2c.Bus --sda=sda-pin --scl=scl-pin --frequency=frequency

  // Initialise Display - stop if not present.
  if not bus.test Ssd1306.I2C-ADDRESS:
    logger.error "No SSD1306 display found"
    return
  ssd1306-device = bus.device Ssd1306.I2C-ADDRESS // --height=32 for the smaller display
  ssd1306-driver = Ssd1306.i2c ssd1306-device
  pixel-display = PixelDisplay.two-color ssd1306-driver
  pixel-display.background = BLACK

  // Enable screen updates in the background regardless of activity
  start-auto-screen-update

  // Establish Display fonts and styles
  font-sans-24/Font      := Font [sans-24.ASCII, sans-24.LATIN-1-SUPPLEMENT]
  font-sans-24-b/Font    := Font [sans-24-bold.ASCII, sans-24-bold.LATIN-1-SUPPLEMENT]
  style-sans-24-bc/Style  := Style --font=font-sans-24-b --color=WHITE --align-center

  font-sans-08/Font      := Font [sans-08.ASCII, sans-08.LATIN-1-SUPPLEMENT]
  font-sans-08-b/Font    := Font [sans-08-bold.ASCII, sans-08-bold.LATIN-1-SUPPLEMENT]
  style-sans-08-l/Style  := Style --font=font-sans-08 --color=WHITE
  style-sans-08-r/Style  := Style --font=font-sans-08 --color=WHITE --align-right
  style-sans-08-c/Style  := Style --font=font-sans-08 --color=WHITE --align-center
  style-sans-08-bc/Style := Style --font=font-sans-08-b --color=WHITE --align-center
  default-style-map      := Style --type-map={"label": style-sans-08-l} --align-center
  pixel-display.set-styles [default-style-map]

  // Establish display layout: roll location and title bar
  [
    Label --x=0   --y=16 --id="header-l"  --style=style-sans-08-l,
    Label --x=64  --y=10 --id="header-c"  --style=style-sans-08-bc,
    Label --x=128 --y=10 --id="header-r"  --style=style-sans-08-r,
    Label --x=0   --y=30 --id="info1-l" --style=style-sans-08-l,
    Label --x=64  --y=38 --id="info1-c" --style=style-sans-24-bc,
    Label --x=128 --y=30 --id="info1-r" --style=style-sans-08-r,
  ].do: pixel-display.add it

  // Establish running animation but hold on to the label reference for later
  info-icon := Label --x=(ssd1306-driver.width / 2) --y=((ssd1306-driver.height / 2) + 7)  --id="info1-icon" --alignment=ALIGN-CENTER

  // Dynamically create rows and columns to display results on SSD.  Works by
  // calculating positions based on the dice size, and creating dynamically
  // creating labels for those in the pixel-display object.
  x-pos := ?
  y-pos := ?
  row := ?
  column := ?
  roll-index := min-roll
  screen-width := ssd1306-driver.width
  screen-rows  := 2
  roll-set := max-roll - min-roll + 1
  screen-columns := 0
  if (roll-set % 2 == 0):
    screen-columns = roll-set / 2
  else:
    screen-columns = (roll-set + 1) / 2
  cell-width := screen-width / screen-columns

  screen-rows.repeat:
    row = it
    y-pos = 50 + (10 * row)
    screen-columns.repeat:
      column = it
      x-pos = (column * cell-width) + (cell-width / 2)
      pixel-display.add (Label --id="dist-$(roll-index)" --style=style-sans-08-c --x=x-pos --y=y-pos)
      roll-index += 1

  header-c := pixel-display.get-element-by-id "header-c"
  header-r := pixel-display.get-element-by-id "header-r"
  roll-display-text := pixel-display.get-element-by-id "info1-c"
  header-c.text = "Digital Dice"
  header-r.text = "D$(roll-set)"
  pixel-display.draw
  logger.info "Dice Range: D$(max-roll - min-roll) ($(min-roll)-$(max-roll))"

  if not bus.test Mpu6050.I2C_ADDRESS:
    logger.error "No Mpu60x0 device found."
    return
  mpu6050-device = bus.device Mpu6050.I2C_ADDRESS
  mpu6050-driver = Mpu6050 mpu6050-device

  // Configure Interrupt Pin, Defaults, and wake MPU6050
  interrupt-pin = gpio.Pin INTERRUPT-PIN-NUMBER --input
  mpu6050-driver.set-clock-source Mpu6050.CLOCK-SRC-INTERNAL-8MHZ
  mpu6050-driver.wakeup-now

  // Reset all internal signal paths
  mpu6050-driver.reset-gyroscope
  mpu6050-driver.reset-accelerometer
  mpu6050-driver.reset-temperature

  // Disable Unused Bits
  mpu6050-driver.disable-temperature

  // Configure Digital High Pass Filter - so slow tilt doesn’t look like motion.
  mpu6050-driver.set-accelerometer-high-pass-filter Mpu6050.ACCEL-HPF-0-63HZ

  // Set Motion Detection
  mpu6050-driver.set-motion-detection-duration-ms STILL-TO-MOTION-MS
  mpu6050-driver.set-motion-detection-threshold-mg STILL-TO-MOTION-MG
  mpu6050-driver.set-motion-detection-count-decrement-rate 1
  //driver.enable-motion-detection-interrupt

  // Set Zero Motion Detection
  mpu6050-driver.set-zero-motion-detection-duration-ms MOTION-TO-STILL-MS
  mpu6050-driver.set-zero-motion-detection-threshold-mg MOTION-TO-STILL-MG
  mpu6050-driver.enable-zero-motion-detection-interrupt

  // Set decrement rates and delay for freefall and motion detection
  mpu6050-driver.set-free-fall-count-decrement-rate 1
  mpu6050-driver.set-acceleration-wake-delay-ms 5

  // Set interrupt pin to go low when activated (original wrote 140 to 0x37)
  mpu6050-driver.set-interrupt-pin-active-low
  mpu6050-driver.disable-fsync-pin

  // Set up interaction - keep pin active until values read.
  mpu6050-driver.enable-interrupt-pin-latching
  mpu6050-driver.set-interrupt-pin-read-clears
  mpu6050-driver.set-dlpf-config 3

  // Prepare variables used in the main routine loop
  motdt-status := ?
  entropy-pool := ?
  iteration := ?
  roll/int := ?
  roll-count := 0
  circle-count/float := 0.0
  accel-read := ?
  gyro-read := ?
  magnitude := 0.0

  // Establish once as oppose to check for exists each roll.
  (max-roll - min-roll + 1).repeat:
    distribution-map[it + 1] = 0
  start-auto-distribution-update
  start-battery-display-update-task

  // Start sleep watchdog to sleep when not in use
  //start-sleep-watchdog-task

  // clear any stale latched flags until now
  mpu6050-driver.get-interrupt-status

  // Main Routine
  while true:
    // Waits for a change in status indicated by the Interrupt Pin
    interrupt-pin.wait-for 0
    last-touch-monotonic = Time.monotonic-us
    //intpt-status = mpu6050-driver.get-interrupt-status
    motdt-status = mpu6050-driver.get-motion-detect-status

    // Motion to Zero Motion (Stopping):
    if (motdt-status & Mpu6050.MOT-DETECT-MOT-TO-ZMOT) != 0:
      //print "  Motion Detected - Stopping"

    // Zero Motion to Motion (Moving):
    //if (motdt-status & Mpu6050.MOT-DETECT-MOT-TO-ZMOT) == 0:
    else:
      //print "  Motion Detected - Starting"
      entropy-pool = sha.Sha256
      pixel-display.add info-icon
      iteration = 0
      circle-count = 0.0
      //while interrupt-pin.get != 0:
      while not ((mpu6050-driver.get-motion-detect-status & Mpu6050.MOT-DETECT-MOT-TO-ZMOT) != 0):
        roll-display-text.text = ""
        accel-read = mpu6050-driver.read-acceleration
        gyro-read = mpu6050-driver.read-gyroscope
        magnitude = mpu6050-driver.magnitude accel-read

        // Faux Force Meter
        if magnitude > 1.3: circle-count += 1.0
        if circle-count < 1:
          info-icon.icon = icons-32.ALERT-CIRCLE-OUTLINE
        else if circle-count < 2:
          info-icon.icon = icons-32.CIRCLE-SLICE-1
        else if circle-count < 3:
          info-icon.icon = icons-32.CIRCLE-SLICE-2
        else if circle-count < 4:
          info-icon.icon = icons-32.CIRCLE-SLICE-3
        else if circle-count < 5:
          info-icon.icon = icons-32.CIRCLE-SLICE-4
        else if circle-count < 6:
          info-icon.icon = icons-32.CIRCLE-SLICE-5
        else if circle-count < 7:
          info-icon.icon = icons-32.CIRCLE-SLICE-6
        else if circle-count < 8:
          info-icon.icon = icons-32.CIRCLE-SLICE-7
        else if circle-count < 9:
          info-icon.icon = icons-32.CIRCLE-SLICE-8
        else:
          info-icon.icon = icons-32.CHECK-CIRCLE-OUTLINE
        pixel-display.draw

        // Add data to pool
        entropy-pool.add (tison.encode Time.monotonic-us)
        entropy-pool.add accel-read.to-byte-array
        entropy-pool.add gyro-read.to-byte-array

        // Yield and Iterate
        sleep --ms=100
        iteration += 1

      roll = sha256-digest-to-range entropy-pool.get --min=min-roll --max=max-roll
      distribution-map[roll] += 1
      roll-count += 1

      //logger.info "  You Rolled: $(roll) /($roll-count) \t Distribution: $(show-distribution distribution --display=pixel-display)"
      logger.info "Dice rolled: $(roll) /($roll-count)"
      pixel-display.remove info-icon
      roll-display-text.text = "$roll"
      pixel-display.draw

    sleep --ms=250

// set battery management/display tasks
start-battery-display-update-task -> none:
  tp4057-driver := tp4057.Tp4057
  tp4057-driver.set-sampling-size 10
  tp4057-driver.set-sampling-rate 10
  tasks["sleep-watchdog"] = task:: task-display-battery-charge tp4057-driver --refresh=BATTERY-DISPLAY-REFRESH

task-display-battery-charge driver/tp4057.Tp4057 --refresh/Duration -> none:
  logger.info "task-display-battery-charge: started." --tags={"refresh" : refresh.in-ms}
  soc/float := 0.0
  plugged/bool := false
  element/Label := pixel-display.get-element-by-id "header-l"
  //header-r := pixel-display.get-element-by-id "header-r"
  while true:
    soc = driver.estimate-state-of-charge
    //header-r.text = "$(%0.0f soc)"
    plugged = driver.is-plugged
    //logger.info "task-display-battery-charge:" --tags={"soc": "$(%0.2f soc)"}
    if plugged: element.icon = icons-20.POWER-PLUG
    else if soc > 90: element.icon = icons-20.BATTERY
    else if soc > 80: element.icon = icons-20.BATTERY-90
    else if soc > 70: element.icon = icons-20.BATTERY-80
    else if soc > 60: element.icon = icons-20.BATTERY-70
    else if soc > 50: element.icon = icons-20.BATTERY-60
    else if soc > 40: element.icon = icons-20.BATTERY-50
    else if soc > 30: element.icon = icons-20.BATTERY-40
    else if soc > 20: element.icon = icons-20.BATTERY-30
    else if soc > 10: element.icon = icons-20.BATTERY-20
    else: element.icon = icons-20.BATTERY-ALERT-VARIANT-OUTLINE
    sleep refresh


// runs in the background and will sleep the device if not touched in DURATION
start-sleep-watchdog-task -> none:
  tasks["sleep-watchdog"] = task:: task-sleep-watchdog --wake-duration=WAKE-DURATION --check-duration=CHECK-DURATION

task-sleep-watchdog --wake-duration/Duration --check-duration/Duration -> none:
  logger.info "task-sleep-watchdog: started." --tags={"delay-s" : WAKE-DURATION.in-s, "freq-ms" : CHECK-DURATION.in-ms}
  esp32.enable-external-wakeup INTERRUPT-PIN-NUMBER false
  while true:
    still-duration := Duration --us=(Time.monotonic-us - last-touch-monotonic)
    if still-duration > wake-duration:
      logger.info "task-sleep-watchdog: idle longer than $(wake-duration.in-s)s. Deep Sleep NOW."
      esp32.deep-sleep (Duration --h=24)
    sleep check-duration

start-auto-distribution-update -> none:
  tasks["distribution-update"] = task:: task-display-distribution --sleep-duration=DISTRIBUTION-REFRESH-DURATION

task-display-distribution --sleep-duration/Duration -> none:
  if distribution-map.is-empty:
    logger.error "task-display-distribution: ditribution map empty. Cancelling task."
    return
  logger.info "task-display-distribution: started." --tags={"freq-ms" : sleep-duration.in-ms}
  sum/int := 0
  percent/int := 0
  elements/Map := {:}
  sum-element/Label := pixel-display.get-element-by-id "info1-r"
  distribution-map.keys.sort.do:
    elements[it] = pixel-display.get-element-by-id "dist-$(it)"
  while true:
    sum = 0
    distribution-map.keys.do:
      sum += distribution-map[it]
    if sum > 0:
      sum-element.text = "/ $(sum)"
      elements.do:
        percent = ((distribution-map[it].to-float) / sum * 100).round
        // elements[it].text = "$(it): $(percent)%"
        elements[it].text = "$(percent)%"
    sleep sleep-duration

start-auto-screen-update -> none:
  tasks["screen-update"] = task:: task-update-screen --sleep-duration=SCREEN-REFRESH-DURATION

// Task to update the screen regardless of things going on. Intended to be run
// as a task.  Will block if run directly.
task-update-screen --sleep-duration/Duration -> none:
  logger.info "task-update-screen: started." --tags={"freq-ms" : sleep-duration.in-ms}
  while true:
    pixel-display.draw
    sleep sleep-duration

stop-all-tasks -> none:
  tasks.keys.do:
    tasks[it].cancel
    logger.info "stop-all: stopped task '$(it)'"


// Helper to show the SHA hash as a single string.
byte-array-to-string array/ByteArray -> string:
  outstring := "$array"
  outstring = outstring.replace "0x" "" --all
  outstring = outstring.replace " " "" --all
  outstring = outstring.replace "#" "" --all
  outstring = outstring.replace "," "" --all
  outstring = outstring.replace "[" "" --all
  outstring = outstring.replace "]" "" --all
  return outstring


// Functions for reducing 32 byte number into specific scale roll.  Credit to
// the internet community for this help:

// ceil(log2(n)) for n >= 1
ceil-log2 n/int -> int:
  if n <= 1: return 0
  bits := 0
  v := n - 1
  while v > 0:
    v = v >> 1
    bits += 1
  return bits

// Read 'k' bits from 'data' starting at bit 'offset' (MSB-first). Returns int.
// 'data' is bytes; 'offset' is 0-based from the first (leftmost) bit.
read-k-bits data/ByteArray offset/int k/int -> int:
  value := 0
  i := 0
  while i < k:
    bit-index := offset + i
    byte-index := bit-index >> 3
    if byte-index >= data.size:
      logger.error "read-k-bits: out of bits."
      throw "Out of bits"
    // MSB-first within each byte:
    bit-in-byte := 7 - (bit-index & 7)
    b := data[byte-index]
    bit := (b >> bit-in-byte) & 1
    value = (value << 1) | bit
    i += 1
  return value

// Uniformly map a 32 byte SHA-256 digest into [min, max] using only the given bytes.
// No extra hashing; uses bit-level rejection sampling within the 256 bits.
sha256-digest-to-range digest/ByteArray --min/int --max/int -> int:
  if digest.size != 32:
    logger.error "sha256-digest-to-range: expected 32 byte digest." --tags={"digest-size" : digest.size}
    throw "Expected 32 byte SHA-256 digest, but got $digest.size bytes."

  // Normalize bounds.
  lo := min
  hi := max
  if lo > hi:
    t := lo; lo = hi; hi = t

  range := hi - lo + 1
  if range <= 0:
    logger.error "sha256-digest-to-range: out of range." --tags={"range" : range}
    throw "Invalid range"

  // Number of bits per draw.
  k := ceil-log2 range
  if k == 0: return lo  // range == 1

  total-bits := digest.size * 8
  offset := 0
  while offset + k <= total-bits:
    v := read-k-bits digest offset k
    offset += k
    if v < range:
      return lo + v

  // Extremely unlikely for a single selection to reach here. As a last-resort
  // fallback, do a tiny-bias modulo on all 256 bits. (Or 'throw' where this is
  // unsuitable.) Convert first to a big int from bytes (MSB-first):
  acc := 0
  digest.do:
    acc = (acc << 8) | it
  logger.warn "sha256-digest-to-range: last-resort - tiny bias modulo"
  return lo + (acc % range)
