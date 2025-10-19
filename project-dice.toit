// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import log
import gpio
import i2c
import math
import mpu6050 show *
import encoding.tison

import ssd1306 show *
import pixel-display show *
import pixel-display.two-color show *

import font show *
import font-x11-adobe.sans-08
import font-x11-adobe.sans-08-bold
import font-x11-adobe.sans-24
import font-x11-adobe.sans-24-bold

import pictogrammers-icons.size-32 as icons

import crypto.sha

/*
A Toit project for Digital Dice

Originally an arduino project using MKR1010 Wifi hardware with a led matrix
board, I wanted digital dice (originally D6, but after talking to others,
D<anything>)  to be able to demonstrate random number generation and at some
point subtly demonstrate manipulating/determining game outcomes due to bad
'randomness' in the number generation.

First outcome:  Good Randomness

Second Outcome: Control of dice without using buttons. Envisioned operation:
  1. Turn on, leave for 5 sec to learn 'up' orientation
  2. Establish x of Dx: shake 'up' to increase number, 'down' to reduce.
  3. Leave for 5 sec.
  4. Shake to create entropy, keep shaking as desired.
  5. Leave on table for 2 sec to finalise and show digit.
  6. Repeat 4 through 6.
  7. After 60 sec go into sleep (or ESP32 Deep Sleep).
  8. Motion detection (on pin) wakes device again, repeat 4 through 7.

Third Outcome:
Implementing compromised generation  (not done yet)

Version 1:  First Idea was to following the [work of
  others](https://gist.github.com/bloc97/b55f684d17edd8f50df8e918cbc00f94) to
  use accelerometer data, based on the ideas that moving the device twice in
  exactly the same way is practically impossible.  Not reliable according to
  some because:
  - Bias & correlation: neighboring accel bits aren’t i.i.d.; axes are coupled.
  - Determinism under motion: an attacker (or just vibration) can steer outputs.
  - Digital filtering: HPF/DLPF settings can reduce true noise if set wrong.
  - No conditioning: XORs help, but they don’t guarantee uniformity.

Version 2:  Better/combined entropy collection

*/

sda-pin-number := 19    // please set these correctly for your device
scl-pin-number := 20    // please set these correctly for your device
interrupt-pin-number := 6

min-roll := 1
max-roll := 7

main:
  ssd1306-device := ?
  ssd1306-driver := ?
  pixel-display := ?

  // Enable and drive I2C:
  frequency := 400_000
  sda-pin := gpio.Pin sda-pin-number
  scl-pin := gpio.Pin scl-pin-number
  bus := i2c.Bus --sda=sda-pin --scl=scl-pin --frequency=frequency

  // Initialise Display, throw if not present.
  if not bus.test Ssd1306.I2C-ADDRESS:
    throw "No SSD1306 display found"
    return

  ssd1306-device = bus.device Ssd1306.I2C-ADDRESS // --height=32 for the smaller display
  ssd1306-driver = Ssd1306.i2c ssd1306-device
  pixel-display = PixelDisplay.two-color ssd1306-driver
  pixel-display.background = BLACK
  pixel-display.draw

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

  [
    Label --x=64 --y=10 --id="header"  --style=style-sans-08-bc,
    Label --x=64 --y=38 --id="info1-c" --style=style-sans-24-bc,
    Label --x=128 --y=30 --id="info1-r" --style=style-sans-08-r,
  ].do: pixel-display.add it

  info-icon := Label --x=(ssd1306-driver.width / 2) --y=((ssd1306-driver.height / 2) + 7)  --id="info1-icon" --alignment=ALIGN-CENTER


  row := ?
  column := ?
  roll-index := min-roll
  x := ?
  y := ?
  screen-width := ssd1306-driver.width
  screen-rows  := 2
  screen-columns := ?
  roll-set := max-roll - min-roll + 1
  if (roll-set % 2 == 0):
    screen-columns = roll-set / 2
  else:
    screen-columns = (roll-set + 1) / 2
  cell-width := screen-width / screen-columns

  screen-rows.repeat:
    row = it
    y = 50 + (10 * row)
    screen-columns.repeat:
      column = it
      x = (column * cell-width) + (cell-width / 2)
      pixel-display.add (Label --id="dist-$(roll-index)" --style=style-sans-08-c --x=x --y=y)
      roll-index += 1

  header := pixel-display.get-element-by-id "header"
  roll-display-text := pixel-display.get-element-by-id "info1-c"
  //roll-display-icon := pixel-display.get-element-by-id "info1-icon"
  header.text = "Digital Dice"
  pixel-display.draw

  if not bus.test Mpu6050.I2C_ADDRESS:
    print " No Mpu60x0 device found"
    return

  print " Found Mpu60x0 on 0x$(%02x Mpu6050.I2C_ADDRESS)"
  device := bus.device Mpu6050.I2C_ADDRESS
  driver := Mpu6050 device

  // Configure Interrupt Pin + Defaults
  interrupt-pin := gpio.Pin interrupt-pin-number --input
  driver.set-clock-source Mpu6050.CLOCK-SRC-INTERNAL-8MHZ
  driver.wakeup-now

  // Reset all internal signal paths
  driver.reset-gyroscope
  driver.reset-accelerometer
  driver.reset-temperature

  // Disable Unused Bits
  driver.disable-temperature

  // Configure Digital High Pass Filter - so slow tilt doesn’t look like motion.
  driver.set-accelerometer-high-pass-filter Mpu6050.ACCEL-HPF-0-63HZ
  // MOT: MOT_THR ~ 20–40 mg, MOT_DUR ~ 20–50 ms.
  // ZMOT: ZRMOT_THR ~ 5–10 mg, ZRMOT_DUR ~ 250–600 ms.
  // INT pin latched, “read clears” enabled. Disable FSYNC unless wired.

  // Set Motion Detection
  driver.set-motion-detection-duration-ms 40
  driver.set-motion-detection-threshold-mg 5
  driver.set-motion-detection-count-decrement-rate 1
  //driver.enable-motion-detection-interrupt

  // Set Zero Motion Detection
  driver.set-zero-motion-detection-duration-ms 600
  driver.set-zero-motion-detection-threshold-mg 10
  driver.enable-zero-motion-detection-interrupt

  // Set decrement rates and delay for freefall and motion detection
  driver.set-free-fall-count-decrement-rate 1

  driver.set-acceleration-wake-delay-ms 5

  // Set interrupt pin to go low when activated (original wrote 140 to 0x37)
  driver.set-interrupt-pin-active-low
  driver.disable-fsync-pin

  // Set up interaction - keep pin active until values read.
  driver.enable-interrupt-pin-latching
  driver.set-interrupt-pin-read-clears
  driver.set-dlpf-config 3

  // clear any stale latched flags
  driver.get-interrupt-status

  // At this point we wait....  When the motion detection triggers, the pin
  // will activate and we go get a value.
  // intpt-status := ?
  motdt-status := ?
  entropy-pool := ?
  iteration := ?
  roll/int := ?
  distribution/Map := {:}
  (max-roll - min-roll + 1).repeat:
    distribution[it + 1] = 0

  while true:
    // Waits for a change in status indicated by the Interrupt Pin
    interrupt-pin.wait-for 0
    //intpt-status = driver.get-interrupt-status
    motdt-status = driver.get-motion-detect-status

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
      while interrupt-pin.get != 0:
        roll-display-text.text = ""
        if iteration % 2 == 0:
          info-icon.icon = icons.CACHED
        else:
          info-icon.icon = icons.SYNC
        pixel-display.draw
        entropy-pool.add (tison.encode Time.monotonic-us)
        entropy-pool.add (driver.read-acceleration).to-byte-array
        entropy-pool.add (driver.read-gyroscope).to-byte-array
        sleep --ms=100
        iteration += 1

      roll = sha256-digest-to-range entropy-pool.get --min=min-roll --max=max-roll
      distribution[roll] += 1

      print "  You Rolled: $(roll) \t Distribution: $(show-distribution distribution --display=pixel-display)"
      pixel-display.remove info-icon
      roll-display-text.text = "$roll"

      pixel-display.draw
    sleep --ms=250


show-distribution dist/Map --display -> string:
  outstring := ""
  sum/int := 0
  percent/int := 0
  dist.keys.do:
    sum += dist[it]
  (display.get-element-by-id "info1-r").text = "/ $(sum)"
  dist.keys.sort.do:
    percent = ((dist[it].to-float) / sum * 100).round
    outstring = "$(outstring) \t [$(it):$(percent)%]"
    // (display.get-element-by-id "dist-$(it)").text = "$(it): $(percent)%"
    (display.get-element-by-id "dist-$(it)").text = "$(percent)%"
  return outstring


// Helpers
byte-array-to-string array/ByteArray -> string:
  outstring := "$array"
  outstring = outstring.replace "0x" "" --all
  outstring = outstring.replace " " "" --all
  outstring = outstring.replace "#" "" --all
  outstring = outstring.replace "," "" --all
  outstring = outstring.replace "[" "" --all
  outstring = outstring.replace "]" "" --all
  return outstring


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
    if byte-index >= data.size: throw "Out of bits"
    // MSB-first within each byte:
    bit-in-byte := 7 - (bit-index & 7)
    b := data[byte-index]
    bit := (b >> bit-in-byte) & 1
    value = (value << 1) | bit
    i += 1
  return value

// Uniformly map a 32-byte SHA-256 digest into [min, max] using only the given bytes.
// No extra hashing; uses bit-level rejection sampling within the 256 bits.
sha256-digest-to-range digest/ByteArray --min/int --max/int -> int:
  if digest.size != 32: throw "Expected 32-byte SHA-256 digest"

  // Normalize bounds.
  lo := min
  hi := max
  if lo > hi:
    t := lo; lo = hi; hi = t

  range := hi - lo + 1
  if range <= 0: throw "Invalid range"

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

  // Extremely unlikely for a single selection to reach here.
  // As a last-resort fallback, do a tiny-bias modulo on all 256 bits.
  // (Or 'throw' if you prefer zero-bias-or-nothing.)
  // Convert first to a big int from bytes (MSB-first):
  acc := 0
  digest.do:
    acc = (acc << 8) | it
  return lo + (acc % range)



  /**
  Random Number Generation

  Following blog post: https://gist.github.com/bloc97/b55f684d17edd8f50df8e918cbc00f94

  Text: The MPU6050 is a multipurpose Accelerometer and Gyroscope sensor module
   for the Arduino, it can read raw acceleration from 3 axis and raw turn rate
   from 3 orientations. To our surprise, its acceleration sensor's noise level
   far surpasses its resolution, with at least 4 bits of recorded entropy.

  A naive approach to generate a random byte would to directly take the 4 least
   significant bits of the x and y axis, XORed with the z axis LSBs. //X, Y, Z
   are 4-bit values from each axis:

   randomByte := ((Y ^ Z) << 4) | (X ^ Z))

  Unfortunately this method is flawed as the distribution and bias of the noise
   is different and unpredictable between axes, not to mention other sensors of
   the same model. A simple fix would be to discard some bits and only use 2 bits
   from each axis, but that would yield only 6 bits of noise per reading, making
   it impossible to generate a 8-bit number with only one data sample of the
   accelerometer.

  However with clever transposition, we can achieve 8 bits of randomness using 4
   bits that are not necessarily the same magnitude from each axis. We are
   supposing that the upper 2 bits are not always reliable, so we will XOR each
   axis' higher 2 bits with another axis' lower 2 bits, and vice-versa.  An
   important property to note is the "piling-up lemma"[4], which states that
   XORing a good random source with a bad one is not harmful. Since we have 3
   axis, each having 4 bits, we will obtain 8 bits at the end. This operation
   is similar to Convolution:

   randomByte := ((X & 0x3) << 6) ^ (Z << 4) ^ (Y << 2) ^ X ^ (Z >> 2)

  This final method achieves state of the art performance for True Random Number
   Generation on the Arduino, with our tests providing us around 8000 random bits
   per second on an Arduino Uno.
  */

/*
get-random-number -> int:
  // Read acceleromter data
  a-x := read-register_ REG-ACCEL-XOUT_ --signed
  a-y := read-register_ REG-ACCEL-YOUT_ --signed
  a-z := read-register_ REG-ACCEL-ZOUT_ --signed

  // Use the second function described above to return a random byte
  random := ((a-x & 0x3) << 6) ^ (a-z << 4) ^ (a-y << 2) ^ a-x ^ (a-z >> 2)
  return random
*/
