// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

// Base imports
import log
import gpio
import i2c
import math
import esp32
import encoding.tison
import tp4057
import system

// Provisioning
import encoding.hex
import provision

// Mpu6050 driver show *
import ..drivers-released.toit-mpu6050.src.mpu6050-dmp-ma612 show *

// Screen Drivers
import ssd1306 show *
import pixel-display show *
import pixel-display.two-color show *
import monitor show Mutex

// Fonts and Icons
import font show *
import font-x11-adobe.sans-08
import font-x11-adobe.sans-08-bold
import font-x11-adobe.sans-24
import font-x11-adobe.sans-24-bold
import pictogrammers-icons.size-32 as icons-32
import pictogrammers-icons.size-20 as icons-20

// SHA library
import crypto.sha

// Storage for
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
MOTION-TO-STILL-MS := 576  // ... for at least this duration of milliseconds.

// Pins for "esp32"
ESP32-SDA-PIN := 26
ESP32-SCL-PIN := 25
ESP32-INTERRUPT-PIN := 34

// Pins for esp32c6
ESP32C6-SDA-PIN := 19
ESP32C6-SCL-PIN := 20
ESP32C6-INTERRUPT-PIN := 4

// Pins for esp32s3
ESP32S3-SDA-PIN := 8
ESP32S3-SCL-PIN := 9
ESP32S3-INTERRUPT-PIN := 4

min-roll := 1
max-roll := 12

SCREEN-REFRESH-DURATION := (Duration --ms=250)         // Screen refreshes this often even if nothing is happening
DISTRIBUTION-REFRESH-DURATION := (Duration --ms=1000)  // Distribution display refreshes this often
WAKE-DURATION := (Duration --s=20)                     // Wait time before deep sleep
CHECK-DURATION := (Duration --ms=500)                  // WAKE-DURATION expiry checked this often
BATTERY-DISPLAY-REFRESH := (Duration --s=30)           // If tp4057 loaded, battery display checked this often
BUFFER-WATCHDOG-SLEEP-DURATION := (Duration --ms=100)  // If using DMP buffer, the buffer size display is refreshed this often
MINIMUM-MAGNITUDE-TO-COUNT := 1.4

/* ..........................AND HERE............................. */

G0 := 9.80665

// Provisioning sec variables:
SEC2-SALT ::= #[
  0x03, 0x6e, 0xe0, 0xc7, 0xbc, 0xb9, 0xed, 0xa8,
  0x4c, 0x9e, 0xac, 0x97, 0xd9, 0x3d, 0xec, 0xf4]

/** See $SEC2-SALT. */
SEC2-VERIFIER ::= #[
  0x7c, 0x7c, 0x85, 0x47, 0x65, 0x08, 0x94, 0x6d,
  0xd6, 0x36, 0xaf, 0x37, 0xd7, 0xe8, 0x91, 0x43,
  0x78, 0xcf, 0xfd, 0x61, 0x6c, 0x59, 0xd2, 0xf8,
  0x39, 0x08, 0x12, 0x72, 0x38, 0xde, 0x9e, 0x24,
  0xa4, 0x70, 0x26, 0x1c, 0xdf, 0xa9, 0x03, 0xc2,
  0xb2, 0x70, 0xe7, 0xb1, 0x32, 0x24, 0xda, 0x11,
  0x1d, 0x97, 0x18, 0xdc, 0x60, 0x72, 0x08, 0xcc,
  0x9a, 0xc9, 0x0c, 0x48, 0x27, 0xe2, 0xae, 0x89,
  0xaa, 0x16, 0x25, 0xb8, 0x04, 0xd2, 0x1a, 0x9b,
  0x3a, 0x8f, 0x37, 0xf6, 0xe4, 0x3a, 0x71, 0x2e,
  0xe1, 0x27, 0x86, 0x6e, 0xad, 0xce, 0x28, 0xff,
  0x54, 0x46, 0x60, 0x1f, 0xb9, 0x96, 0x87, 0xdc,
  0x57, 0x40, 0xa7, 0xd4, 0x6c, 0xc9, 0x77, 0x54,
  0xdc, 0x16, 0x82, 0xf0, 0xed, 0x35, 0x6a, 0xc4,
  0x70, 0xad, 0x3d, 0x90, 0xb5, 0x81, 0x94, 0x70,
  0xd7, 0xbc, 0x65, 0xb2, 0xd5, 0x18, 0xe0, 0x2e,
  0xc3, 0xa5, 0xf9, 0x68, 0xdd, 0x64, 0x7b, 0xb8,
  0xb7, 0x3c, 0x9c, 0xfc, 0x00, 0xd8, 0x71, 0x7e,
  0xb7, 0x9a, 0x7c, 0xb1, 0xb7, 0xc2, 0xc3, 0x18,
  0x34, 0x29, 0x32, 0x43, 0x3e, 0x00, 0x99, 0xe9,
  0x82, 0x94, 0xe3, 0xd8, 0x2a, 0xb0, 0x96, 0x29,
  0xb7, 0xdf, 0x0e, 0x5f, 0x08, 0x33, 0x40, 0x76,
  0x52, 0x91, 0x32, 0x00, 0x9f, 0x97, 0x2c, 0x89,
  0x6c, 0x39, 0x1e, 0xc8, 0x28, 0x05, 0x44, 0x17,
  0x3f, 0x68, 0x02, 0x8a, 0x9f, 0x44, 0x61, 0xd1,
  0xf5, 0xa1, 0x7e, 0x5a, 0x70, 0xd2, 0xc7, 0x23,
  0x81, 0xcb, 0x38, 0x68, 0xe4, 0x2c, 0x20, 0xbc,
  0x40, 0x57, 0x76, 0x17, 0xbd, 0x08, 0xb8, 0x96,
  0xbc, 0x26, 0xeb, 0x32, 0x46, 0x69, 0x35, 0x05,
  0x8c, 0x15, 0x70, 0xd9, 0x1b, 0xe9, 0xbe, 0xcc,
  0xa9, 0x38, 0xa6, 0x67, 0xf0, 0xad, 0x50, 0x13,
  0x19, 0x72, 0x64, 0xbf, 0x52, 0xc2, 0x34, 0xe2,
  0x1b, 0x11, 0x79, 0x74, 0x72, 0xbd, 0x34, 0x5b,
  0xb1, 0xe2, 0xfd, 0x66, 0x73, 0xfe, 0x71, 0x64,
  0x74, 0xd0, 0x4e, 0xbc, 0x51, 0x24, 0x19, 0x40,
  0x87, 0x0e, 0x92, 0x40, 0xe6, 0x21, 0xe7, 0x2d,
  0x4e, 0x37, 0x76, 0x2f, 0x2e, 0xe2, 0x68, 0xc7,
  0x89, 0xe8, 0x32, 0x13, 0x42, 0x06, 0x84, 0x84,
  0x53, 0x4a, 0xb3, 0x0c, 0x1b, 0x4c, 0x8d, 0x1c,
  0x51, 0x97, 0x19, 0xab, 0xae, 0x77, 0xff, 0xdb,
  0xec, 0xf0, 0x10, 0x95, 0x34, 0x33, 0x6b, 0xcb,
  0x3e, 0x84, 0x0f, 0xb9, 0xd8, 0x5f, 0xb8, 0xa0,
  0xb8, 0x55, 0x53, 0x3e, 0x70, 0xf7, 0x18, 0xf5,
  0xce, 0x7b, 0x4e, 0xbf, 0x27, 0xce, 0xce, 0xa8,
  0xb3, 0xbe, 0x40, 0xc5, 0xc5, 0x32, 0x29, 0x3e,
  0x71, 0x64, 0x9e, 0xde, 0x8c, 0xf6, 0x75, 0xa1,
  0xe6, 0xf6, 0x53, 0xc8, 0x31, 0xa8, 0x78, 0xde,
  0x50, 0x40, 0xf7, 0x62, 0xde, 0x36, 0xb2, 0xba]

USER-NAME ::= "wifiprov"
USER-KEY ::= "abcd1234"

// Global variables (for sharing between functions)
logger/log.Logger := ?
distribution-map := ?
pixel-display := ?
tasks/Map := {:}
last-touch-monotonic/int := Time.monotonic-us
interrupt-pin/gpio.Pin := ?

mpu6050-device := ?
mpu6050-driver := ?
roll-display := ?
info-icon := ?
display-mutex := ?
sda-pin-number := ?
scl-pin-number := ?
interrupt-pin-number := ?
bucket/storage.Bucket := ?
dice-type/string := ?

main:
  // Prepare Logger
  logger = log.default.with-name "project-dice"

  // Rudimentary Chip/Pin Selection
  sda-pin-number = ESP32-SDA-PIN
  scl-pin-number = ESP32-SCL-PIN
  interrupt-pin-number = ESP32-INTERRUPT-PIN
  if system.architecture == "esp32c6":
    sda-pin-number = ESP32C6-SDA-PIN
    scl-pin-number = ESP32C6-SCL-PIN
    interrupt-pin-number = ESP32C6-INTERRUPT-PIN
  else if system.architecture == "esp32s3":
    sda-pin-number = ESP32S3-SDA-PIN
    scl-pin-number = ESP32S3-SCL-PIN
    interrupt-pin-number = ESP32S3-INTERRUPT-PIN

  // Wifi Provisioner (as background task)
  //tasks["provisioner"] = task:: initialize-provisioning

  // Print memory before even starting
  //system.print-objects

  // We don't want separate tasks updating the display at the
  // same time, so this mutex is used to ensure the tasks only
  // have access one at a time.
  display-mutex = Mutex

  // Prepare Variables
  ssd1306-device := ?
  ssd1306-driver := ?

  // Enable and drive I2C
  frequency := 400_000
  sda-pin := gpio.Pin sda-pin-number
  scl-pin := gpio.Pin scl-pin-number
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
  info-icon = Label --x=(ssd1306-driver.width / 2) --y=((ssd1306-driver.height / 2) + 7)  --id="info1-icon" --alignment=ALIGN-CENTER

  // Dynamically create rows and columns to display results on SSD.  Works by
  // calculating positions based on the dice size, and creating dynamically
  // creating labels for those in the pixel-display object.
  roll-set := max-roll - min-roll + 1
  dice-type = "D$(roll-set)"
  x-pos := ?
  y-pos := ?
  row := ?
  column := ?
  roll-index := min-roll
  screen-width := ssd1306-driver.width
  screen-rows  := 2
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
  roll-display = pixel-display.get-element-by-id "info1-c"
  roll-display-magnitude := pixel-display.get-element-by-id "info1-l"
  display-mutex.do:
    header-c.text = "Digital Dice"
    header-r.text = "$(dice-type)"
    pixel-display.draw
  logger.info "Dice Range: D$(max-roll - min-roll + 1) ($(min-roll)-$(max-roll))"

  if not bus.test Mpu6050-dmp-ma612.I2C_ADDRESS:
    logger.error "No Mpu60x0 device found."
    return
  mpu6050-device = bus.device Mpu6050-dmp-ma612.I2C_ADDRESS
  mpu6050-driver = Mpu6050-dmp-ma612 mpu6050-device

  // Configure Interrupt Pin, Defaults, and wake MPU6050
  interrupt-pin = gpio.Pin interrupt-pin-number --input  --pull-down
  mpu6050-driver.set-clock-source Mpu6050-dmp-ma612.CLOCK-SRC-INTERNAL-8MHZ
  mpu6050-driver.wakeup-now

  // Reset all internal signal paths
  mpu6050-driver.reset-gyroscope
  mpu6050-driver.reset-accelerometer
  mpu6050-driver.reset-temperature

  // Disable Unused Bits
  mpu6050-driver.disable-temperature

  // Configure Digital High Pass Filter - so slow tilt doesn’t look like motion.
  mpu6050-driver.set-accelerometer-high-pass-filter Mpu6050-dmp-ma612.ACCEL-HPF-0-63HZ

  // Set Motion Detection
  mpu6050-driver.set-motion-detection-duration-ms STILL-TO-MOTION-MS
  mpu6050-driver.set-motion-detection-threshold-mg STILL-TO-MOTION-MG
  mpu6050-driver.set-motion-detection-count-decrement-rate 1
  //driver.enable-motion-detection-interrupt

  // Set interrupt pin to go low when activated (original wrote 140 to 0x37)
  mpu6050-driver.set-interrupt-pin-active-high
  mpu6050-driver.disable-fsync-pin

  // Set up interaction - keep pin active until values read.
  mpu6050-driver.enable-interrupt-pin-latching
  mpu6050-driver.set-interrupt-pin-read-clears
  mpu6050-driver.set-dlpf-config Mpu6050-dmp-ma612.CONFIG-DLPF-3

  // Enable DMP
  //mpu6050-driver.enable-dmp
  //mpu6050-driver.show-interrupts

  // Set Zero Motion Detection
  mpu6050-driver.set-zero-motion-detection-duration-ms MOTION-TO-STILL-MS
  mpu6050-driver.set-zero-motion-detection-threshold-mg MOTION-TO-STILL-MG
  mpu6050-driver.enable-interrupt-zero-motion-detection

  // Set decrement rates and delay for freefall and motion detection
  mpu6050-driver.set-free-fall-count-decrement-rate 1
  mpu6050-driver.set-acceleration-wake-delay-ms 5


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
  mag-this-iteration := 0.0

  // Use RAM-backed bucket and cope when there is nothing there.
  // Establish once as oppose to check for exists each roll.
  bucket = storage.Bucket.open --ram "project-dice"
  bucket-dice-type := ""
  bucket-present := true
  bucket-dice-type = bucket.get "dice-type"
      --if-absent=:
        bucket-present = false

  logger.info "bucket-dice-type: type=$(bucket-dice-type) present=$(bucket-present)"
  if bucket-present and (bucket-dice-type == dice-type) and (bucket["distribution-map"] is Map):
    bucket-dice-type = bucket.get "dice-type"
    distribution-map = bucket["distribution-map"]
    bucket["dice-type"] = dice-type
  else:
    if (bucket-dice-type != dice-type):
      logger.info "Change in dice-type - resetting distribution."
    else:
      logger.info "Restarting distribution."
    distribution-map = {:}
    (max-roll - min-roll + 1).repeat:
      distribution-map[it + 1] = 0 //.update (it + 1) --init=0
    bucket["distribution-map"] = distribution-map
    bucket["dice-type"] = dice-type

  logger.info "Distribution map: $(bucket["distribution-map"])"
  start-auto-distribution-update
  start-battery-display-update-task

  if mpu6050-driver.is-dmp-enabled: start-buffer-watchdog-task
  sleep --ms=100

  // Start sleep watchdog to sleep when not in use
  start-sleep-watchdog-task

  // clear any stale latched flags until now
  mpu6050-driver.get-interrupt-status

  // Get current gravity unit vector in current frame
  g-direction := mpu6050-driver.read-accelerometer

  // Main Routine
  while true:
    // Waits for a change in status indicated by the Interrupt Pin
    logger.info "Waiting for Interrupt..."
    interrupt-pin.wait-for 1
    //intpt-status = mpu6050-driver.get-interrupt-status
    motdt-status = mpu6050-driver.get-motion-detect-status
    mpu6050-driver.clear-fifo

    // Motion to Zero Motion (Stopping):
    if (motdt-status & Mpu6050-dmp-ma612.MOT-DETECT-MOT-TO-ZMOT) != 0:
      //print "  Motion Detected - Stopping"

    // Zero Motion to Motion (Moving):
    //if (motdt-status & Mpu6050.MOT-DETECT-MOT-TO-ZMOT) == 0:
    else:
      //print "  Motion Detected - Starting"
      entropy-pool = sha.Sha256
      display-mutex.do:
        pixel-display.remove roll-display
        pixel-display.add info-icon
        pixel-display.draw
      iteration = 0
      circle-count = 0.0
      magnitude = 0.0
      //while interrupt-pin.get != 0:
      while not ((mpu6050-driver.get-motion-detect-status & Mpu6050-dmp-ma612.MOT-DETECT-MOT-TO-ZMOT) != 0):
        last-touch-monotonic = Time.monotonic-us

        if (mpu6050-driver.is-dmp-enabled):
          accel-read = mpu6050-driver.read-accelerometer-dmp
          gyro-read = mpu6050-driver.read-gyroscope-dmp
        else:
          accel-read = mpu6050-driver.read-accelerometer
          gyro-read = mpu6050-driver.read-gyroscope

        mag-this-iteration = mpu6050-driver.magnitude accel-read
        //print "mag-this-iteration $(mag-this-iteration)"
        if mag-this-iteration > MINIMUM-MAGNITUDE-TO-COUNT:
          magnitude += mag-this-iteration
          circle-count += 1.0

        // Faux Force Meter
        display-mutex.do:
          roll-display-magnitude.text = "$(%0.2f magnitude)"
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
      bucket["distribution-map"] = distribution-map
      roll-count += 1

      //logger.info "  You Rolled: $(roll) /($roll-count) \t Distribution: $(show-distribution distribution --display=pixel-display)"
      logger.info "Dice rolled: $(roll) /($roll-count)"
      display-mutex.do:
        pixel-display.remove info-icon
        roll-display.text = "$roll"
        pixel-display.add roll-display
        pixel-display.draw

    // Print memory before even starting
    //system.print-objects

    sleep --ms=100

initialize-provisioning -> none:
  // Initialise provisioning
  id := esp32.mac-address[3..]
  service-name := "PROV_" + (hex.encode id)
  logger.info "Provisioning Service Name: $service-name"

  credentials := provision.SecurityCredentials.scheme2
      --salt=SEC2-SALT
      --verifier=SEC2-VERIFIER

  prov := provision.Provision service-name --security-credentials=credentials

  prov.start

  note ::= """
      For a QR code, open the following URL in a browser:

      https://espressif.github.io/esp-jumpstart/qrcode.html?data=\
      {"ver":"v1","name":"$(service-name)","transport":"ble","username":$USER-NAME,"pop":$USER-KEY}

      """
  print note

  logger.info "prov.wait....:"
  wifi-credentials := prov.wait
  logger.info "Received Wi-Fi credentials: $wifi-credentials"
  prov.close

// set battery management/display tasks
start-battery-display-update-task -> none:
  if system.architecture == "esp32c6":
    tp4057-driver := tp4057.Tp4057
    tp4057-driver.set-sampling-size 10
    tp4057-driver.set-sampling-rate 4
    tasks["sleep-watchdog"] = task:: task-display-battery-charge tp4057-driver --refresh=BATTERY-DISPLAY-REFRESH
  else:
    logger.info "start-battery-display-update-task: $(system.architecture) not known to have tp4057. Stopping."

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


start-buffer-watchdog-task -> none:
  tasks["buffer-watchdog"] = task:: task-buffer-watchdog --sleep-duration=BUFFER-WATCHDOG-SLEEP-DURATION

task-buffer-watchdog --sleep-duration/Duration -> none:
  logger.info "buffer-watchdog: started." --tags={"sleep-duration" : sleep-duration.in-ms}
  header-r := pixel-display.get-element-by-id "header-r"
  while true:
    header-r.text = "$(mpu6050-driver.buffer-size)"
    sleep sleep-duration

// runs in the background and will sleep the device if not touched in DURATION
start-sleep-watchdog-task -> none:
  // If the ESP32 wakes up due to the GPIO pins, then reset-reason is set to
  // RESET-DEEPSLEEP and wakeup-cause is set to WAKEUP-EXT1.
  cause := esp32.wakeup-cause
  if cause == esp32.WAKEUP-EXT1:
    logger.info "start-sleep-watchdog-task: previous wakeup caused by pin."
  else if cause == esp32.WAKEUP-TOUCHPAD:
    logger.info "start-sleep-watchdog-task: previous wakeup caused by wakeup-touchpad."
  else if cause == esp32.WAKEUP-GPIO:
    logger.info "start-sleep-watchdog-task: previous wakeup caused by wakeup-touchpad."
  else if cause == esp32.WAKEUP-ULP:
    logger.info "start-sleep-watchdog-task: previous wakeup caused by ULP program."

  if system.architecture == "esp32s3":
    logger.info "start-sleep-watchdog-task: wake on esp32s3 currently unsupported."
    return
  else:
   tasks["sleep-watchdog"] = task:: task-sleep-watchdog --wake-duration=WAKE-DURATION --check-duration=CHECK-DURATION

task-sleep-watchdog --wake-duration/Duration --check-duration/Duration -> none:
  logger.info "task-sleep-watchdog: started." --tags={"delay-s" : WAKE-DURATION.in-s, "freq-ms" : CHECK-DURATION.in-ms, "pin":interrupt-pin-number}
  pin-mask := (1 << interrupt-pin-number)
  esp32.enable-external-wakeup pin-mask true
  header-c := pixel-display.get-element-by-id "header-c"

  while true:
    still-duration := Duration --us=(Time.monotonic-us - last-touch-monotonic)
    header-c.text = "$((wake-duration - still-duration).in-s)"
    if still-duration > wake-duration:
      display-mutex.do:
        pixel-display.remove-all
        pixel-display.add info-icon
        info-icon.icon = icons-32.SLEEP
        header-c.text = "Sleeping..."
        pixel-display.draw
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
      display-mutex.do:
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
    display-mutex.do:
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

linear-acc-from-gravity a/math.Point3f g_dir/math.Point3f -> math.Point3f:
  // a in m/s², g_dir must be unit length
  return math.Point3f (a.x - g_dir.x * G0)
                      (a.y - g_dir.y * G0)
                      (a.z - g_dir.z * G0)
