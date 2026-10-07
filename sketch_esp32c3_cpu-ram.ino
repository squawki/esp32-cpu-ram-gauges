#include <Arduino.h>
#include <math.h>

// -----------------------------------------------------------------------------
// Proxmox Gauge Controller
// -----------------------------------------------------------------------------
//
// ESP32-C3 controller for two moving-coil analogue gauges and an RGB status LED.
//
// The controller receives CPU and RAM utilisation over USB serial and converts
// those values into PWM signals for the gauges.
//
// CPU and RAM values are smoothed independently so the needles show overall
// system activity rather than rapidly following short-term fluctuations.
//
// If communication from the computer is lost, the gauges enter a visual fault
// sweep and the RGB LED changes to solid red.
//
// USB serial protocol:
//   CPU=0       CPU utilisation percentage
//   RAM=0       RAM utilisation percentage
//   LED=RED     Manual LED control
//
// Gauge wiring:
//   GPIO7 -> 2 kΩ resistor -> CPU gauge -> GND
//   GPIO6 -> 2 kΩ resistor -> RAM gauge -> GND
//
// RGB LED:
//   Common cathode -> GND
//   GPIO1 -> red LED channel
//   GPIO2 -> green LED channel
//   GPIO0 -> blue LED channel
//
// Each RGB LED channel requires its own current-limiting resistor.
//
// -----------------------------------------------------------------------------


// -----------------------------------------------------------------------------
// Gauge pins
// -----------------------------------------------------------------------------

const int CPU_GAUGE_PIN = 7;
const int RAM_GAUGE_PIN = 6;


// -----------------------------------------------------------------------------
// RGB LED pins
// -----------------------------------------------------------------------------

const int LED_RED_PIN = 1;
const int LED_GREEN_PIN = 2;
const int LED_BLUE_PIN = 0;


// -----------------------------------------------------------------------------
// ESP32 CPU frequency
// -----------------------------------------------------------------------------
//
// The controller has a very light processing workload, so the CPU is operated
// at 40 MHz rather than the default higher frequency.

const int ESP32_CPU_FREQUENCY_MHZ = 40;


// -----------------------------------------------------------------------------
// PWM configuration
// -----------------------------------------------------------------------------
//
// LEDC hardware PWM is used for both the gauges and RGB LED.
//
// The moving-coil gauges respond to the average current produced by the PWM.
// 500 Hz provides smooth gauge movement without requiring high-frequency
// switching.

const int PWM_FREQUENCY = 500;
const int PWM_RESOLUTION = 12;

const int PWM_MAX = (1 << PWM_RESOLUTION) - 1;


// -----------------------------------------------------------------------------
// Physical gauge limits
// -----------------------------------------------------------------------------
//
// The gauges are driven through 2 kΩ series resistors.
//
// Due to the electrical characteristics of the gauges and the available
// 3.3 V GPIO output, approximately 66% PWM corresponds to 100% of the
// usable physical gauge scale.
//
// Gauge values are therefore converted from a logical 0-100% range to
// this physical limit before PWM is applied.

const float GAUGE_MAX_PERCENT = 66.0f;


// -----------------------------------------------------------------------------
// Gauge smoothing
// -----------------------------------------------------------------------------
//
// CPU and RAM use different smoothing times to produce stable visual
// indications while retaining useful responsiveness.

const float CPU_SMOOTHING_TIME_MS = 250.0f;
const float RAM_SMOOTHING_TIME_MS = 500.0f;


// Gauge update interval.

const unsigned long GAUGE_UPDATE_INTERVAL_MS = 10;


// -----------------------------------------------------------------------------
// Communication / signal monitoring
// -----------------------------------------------------------------------------
//
// The Proxmox host normally sends telemetry once per second.
//
// If no valid CPU or RAM command is received for 3 seconds, communication
// is considered lost and the controller enters fault mode.

const unsigned long SIGNAL_TIMEOUT_MS = 3000;


// -----------------------------------------------------------------------------
// Fault sweep
// -----------------------------------------------------------------------------
//
// During a communication fault, the two gauges continuously sweep between
// zero and their maximum positions in opposite directions.

const unsigned long FAULT_SWEEP_PERIOD_MS = 4000;


// -----------------------------------------------------------------------------
// LED status
// -----------------------------------------------------------------------------
//
// Automatic mode:
//   Blue  = waiting for the first telemetry message
//   Green = telemetry being received normally
//   Red   = communication failure
//
// Manual mode allows the LED colour to be controlled directly.
//
// Communication faults always override the normal LED state and force
// solid red at full brightness.

enum LEDMode
{
  LED_MODE_AUTO,
  LED_MODE_MANUAL
};

LEDMode ledMode = LED_MODE_AUTO;


// -----------------------------------------------------------------------------
// LED on/off state
// -----------------------------------------------------------------------------
//
// The on/off state is independent of the configured brightness.
//
// Turning the LED off does not change the selected colour or dim level.
// A subsequent LED=ON restores the previous normal LED state.
//
// Communication faults temporarily override this state and force the LED on.

bool ledEnabled = true;


// -----------------------------------------------------------------------------
// LED brightness
// -----------------------------------------------------------------------------
//
// Normal default brightness is 50%.
//
// On startup, the LED operates at 100% brightness until the first valid
// telemetry message is received.
//
// Communication faults always use 100% brightness.

const int DEFAULT_LED_DIM_PERCENT = 50;

int ledDimPercent = DEFAULT_LED_DIM_PERCENT;

bool bootFullBrightness = true;


// -----------------------------------------------------------------------------
// Manual LED colour
// -----------------------------------------------------------------------------
//
// The selected RGB colour is retained when the LED is switched off.

int manualLEDRed = 0;
int manualLEDGreen = 0;
int manualLEDBlue = 0;


// -----------------------------------------------------------------------------
// CPU gauge state
// -----------------------------------------------------------------------------

float currentCPUGaugePercent = 0.0f;
float targetCPUGaugePercent = 0.0f;

unsigned long lastCPUUpdate = 0;

int lastCPUPWM = -1;


// -----------------------------------------------------------------------------
// RAM gauge state
// -----------------------------------------------------------------------------

float currentRAMGaugePercent = 0.0f;
float targetRAMGaugePercent = 0.0f;

unsigned long lastRAMUpdate = 0;

int lastRAMPWM = -1;


// -----------------------------------------------------------------------------
// Signal state
// -----------------------------------------------------------------------------

unsigned long lastSignalReceived = 0;

bool signalFault = false;


// -----------------------------------------------------------------------------
// Set RGB LED
// -----------------------------------------------------------------------------
//
// Colour components are supplied as 8-bit values from 0 to 255.
//
// brightnessPercent applies an overall brightness limit to the selected
// colour. Fault indication bypasses the normal dim level and uses 100%.

void setLED(
  int red,
  int green,
  int blue,
  int brightnessPercent = 100
)
{
  red = constrain(red, 0, 255);
  green = constrain(green, 0, 255);
  blue = constrain(blue, 0, 255);

  brightnessPercent =
    constrain(brightnessPercent, 0, 100);

  // Apply overall brightness.
  red =
    (red * brightnessPercent) / 100;

  green =
    (green * brightnessPercent) / 100;

  blue =
    (blue * brightnessPercent) / 100;

  int redPWM =
    (red * PWM_MAX) / 255;

  int greenPWM =
    (green * PWM_MAX) / 255;

  int bluePWM =
    (blue * PWM_MAX) / 255;

  ledcWrite(LED_RED_PIN, redPWM);
  ledcWrite(LED_GREEN_PIN, greenPWM);
  ledcWrite(LED_BLUE_PIN, bluePWM);
}


// -----------------------------------------------------------------------------
// Named LED colours
// -----------------------------------------------------------------------------

void setLEDOff()
{
  setLED(0, 0, 0, 100);
}

void setLEDRed()
{
  setLED(255, 0, 0, 100);
}

void setLEDGreen()
{
  setLED(0, 255, 0, 100);
}

void setLEDBlue()
{
  setLED(0, 0, 255, 100);
}

void setLEDYellow()
{
  setLED(255, 255, 0, 100);
}

void setLEDCyan()
{
  setLED(0, 255, 255, 100);
}

void setLEDMagenta()
{
  setLED(255, 0, 255, 100);
}

void setLEDWhite()
{
  setLED(255, 255, 255, 100);
}


// -----------------------------------------------------------------------------
// Update automatic LED status
// -----------------------------------------------------------------------------
//
// The automatic status is determined by communication state.
//
// Blue indicates that the controller is waiting for telemetry.
// Green indicates normal communication.
// Red indicates communication failure.

void updateAutomaticLED()
{
  if (ledMode != LED_MODE_AUTO)
    return;

  // Communication failure overrides all normal LED settings.
  if (signalFault)
  {
    setLED(
      255,
      0,
      0,
      100
    );

    return;
  }

  if (!ledEnabled)
  {
    setLEDOff();
    return;
  }

  int brightness =
    bootFullBrightness
      ? 100
      : ledDimPercent;

  // Telemetry has been received.
  if (lastSignalReceived != 0)
  {
    setLED(
      0,
      255,
      0,
      brightness
    );

    return;
  }

  // Waiting for the first telemetry message.
  setLED(
    0,
    0,
    255,
    brightness
  );
}


// -----------------------------------------------------------------------------
// Apply the current LED state
// -----------------------------------------------------------------------------
//
// Fault status has the highest priority, followed by the LED on/off state,
// manual mode and automatic mode.

void updateLED()
{
  // Communication fault always takes priority.
  if (signalFault)
  {
    setLED(
      255,
      0,
      0,
      100
    );

    return;
  }

  if (!ledEnabled)
  {
    setLEDOff();
    return;
  }

  if (ledMode == LED_MODE_MANUAL)
  {
    int brightness =
      bootFullBrightness
        ? 100
        : ledDimPercent;

    setLED(
      manualLEDRed,
      manualLEDGreen,
      manualLEDBlue,
      brightness
    );

    return;
  }

  updateAutomaticLED();
}


// -----------------------------------------------------------------------------
// Set gauge position
// -----------------------------------------------------------------------------
//
// physicalPercent is the desired position on the gauge's logical 0-100%
// scale. The value is converted to PWM using the calibrated physical limit.
//
// PWM output is only updated when the calculated value changes.

void setGauge(int pin, float physicalPercent, int &lastPWM)
{
  physicalPercent = constrain(
    physicalPercent,
    0.0f,
    100.0f
  );

  int pwm = (int)(
    (physicalPercent / 100.0f) * PWM_MAX
  );

  if (pwm != lastPWM)
  {
    ledcWrite(pin, pwm);
    lastPWM = pwm;
  }
}


// -----------------------------------------------------------------------------
// Register valid telemetry
// -----------------------------------------------------------------------------
//
// Receiving either a valid CPU or RAM command is sufficient to confirm that
// communication with the host is active.

void signalReceived()
{
  lastSignalReceived = millis();

  if (signalFault)
  {
    signalFault = false;

    Serial.println("SIGNAL RESTORED");

    // Restart smoothing timing when communication resumes.
    lastCPUUpdate = millis();
    lastRAMUpdate = millis();
  }

  // Normal dimming begins after the first valid telemetry message.
  bootFullBrightness = false;
}


// -----------------------------------------------------------------------------
// Check communication status
// -----------------------------------------------------------------------------
//
// If the expected telemetry timeout is exceeded, enter fault mode.

void updateSignalStatus()
{
  unsigned long now = millis();

  // Do not trigger a fault before the first valid command.
  if (lastSignalReceived == 0)
    return;

  unsigned long elapsed =
    now - lastSignalReceived;

  if (!signalFault && elapsed >= SIGNAL_TIMEOUT_MS)
  {
    signalFault = true;

    Serial.println("SIGNAL LOST");
    Serial.println("Entering gauge fault sweep");

    // Immediately display the fault condition.
    updateLED();
  }
}


// -----------------------------------------------------------------------------
// Update fault sweep
// -----------------------------------------------------------------------------
//
// Generates a triangle wave from 0 to 100% and back to 0%.
//
// The CPU and RAM gauges move in opposite directions so that the fault
// condition is immediately visible.

void updateFaultSweep()
{
  if (!signalFault)
    return;

  unsigned long now = millis();

  unsigned long position =
    now % FAULT_SWEEP_PERIOD_MS;

  float phase =
    (float)position / (float)FAULT_SWEEP_PERIOD_MS;

  float sweep;

  if (phase < 0.5f)
  {
    sweep = phase * 2.0f;
  }
  else
  {
    sweep = 1.0f - ((phase - 0.5f) * 2.0f);
  }

  float cpuPosition =
    sweep * GAUGE_MAX_PERCENT;

  float ramPosition =
    (1.0f - sweep) * GAUGE_MAX_PERCENT;

  setGauge(
    CPU_GAUGE_PIN,
    cpuPosition,
    lastCPUPWM
  );

  setGauge(
    RAM_GAUGE_PIN,
    ramPosition,
    lastRAMPWM
  );
}


// -----------------------------------------------------------------------------
// Update CPU gauge
// -----------------------------------------------------------------------------
//
// Moves the gauge towards the latest CPU target using exponential smoothing.
// This prevents the needle from rapidly following short-term changes.

void updateCPUGauge()
{
  if (signalFault)
    return;

  unsigned long now = millis();

  if (lastCPUUpdate == 0)
  {
    lastCPUUpdate = now;

    setGauge(
      CPU_GAUGE_PIN,
      currentCPUGaugePercent,
      lastCPUPWM
    );

    return;
  }

  unsigned long elapsed =
    now - lastCPUUpdate;

  if (elapsed < GAUGE_UPDATE_INTERVAL_MS)
    return;

  lastCPUUpdate = now;

  float dt = (float)elapsed;

  if (dt > 100.0f)
    dt = 100.0f;

  float alpha =
    1.0f - expf(
      -dt / CPU_SMOOTHING_TIME_MS
    );

  currentCPUGaugePercent +=
    (targetCPUGaugePercent - currentCPUGaugePercent)
    * alpha;

  if (
    fabsf(
      targetCPUGaugePercent - currentCPUGaugePercent
    ) < 0.01f
  )
  {
    currentCPUGaugePercent =
      targetCPUGaugePercent;
  }

  setGauge(
    CPU_GAUGE_PIN,
    currentCPUGaugePercent,
    lastCPUPWM
  );
}


// -----------------------------------------------------------------------------
// Update RAM gauge
// -----------------------------------------------------------------------------
//
// Moves the gauge towards the latest RAM target using exponential smoothing.

void updateRAMGauge()
{
  if (signalFault)
    return;

  unsigned long now = millis();

  if (lastRAMUpdate == 0)
  {
    lastRAMUpdate = now;

    setGauge(
      RAM_GAUGE_PIN,
      currentRAMGaugePercent,
      lastRAMPWM
    );

    return;
  }

  unsigned long elapsed =
    now - lastRAMUpdate;

  if (elapsed < GAUGE_UPDATE_INTERVAL_MS)
    return;

  lastRAMUpdate = now;

  float dt = (float)elapsed;

  if (dt > 100.0f)
    dt = 100.0f;

  float alpha =
    1.0f - expf(
      -dt / RAM_SMOOTHING_TIME_MS
    );

  currentRAMGaugePercent +=
    (targetRAMGaugePercent - currentRAMGaugePercent)
    * alpha;

  if (
    fabsf(
      targetRAMGaugePercent - currentRAMGaugePercent
    ) < 0.01f
  )
  {
    currentRAMGaugePercent =
      targetRAMGaugePercent;
  }

  setGauge(
    RAM_GAUGE_PIN,
    currentRAMGaugePercent,
    lastRAMPWM
  );
}


// -----------------------------------------------------------------------------
// Set CPU gauge target
// -----------------------------------------------------------------------------
//
// Converts the received CPU utilisation percentage to the calibrated physical
// gauge range.

void setCPU(float cpuPercent)
{
  cpuPercent = constrain(
    cpuPercent,
    0.0f,
    100.0f
  );

  targetCPUGaugePercent =
    (cpuPercent / 100.0f)
    * GAUGE_MAX_PERCENT;

  Serial.printf(
    "ACK CPU=%.1f\n",
    cpuPercent
  );

  signalReceived();
}


// -----------------------------------------------------------------------------
// Set RAM gauge target
// -----------------------------------------------------------------------------
//
// Converts the received RAM utilisation percentage to the calibrated physical
// gauge range.

void setRAM(float ramPercent)
{
  ramPercent = constrain(
    ramPercent,
    0.0f,
    100.0f
  );

  targetRAMGaugePercent =
    (ramPercent / 100.0f)
    * GAUGE_MAX_PERCENT;

  Serial.printf(
    "ACK RAM=%.1f\n",
    ramPercent
  );

  signalReceived();
}


// -----------------------------------------------------------------------------
// Process LED command
// -----------------------------------------------------------------------------
//
// Supported commands:
//
//   LED=ON
//   LED=OFF
//   LED=DIM,50
//   LED=RED
//   LED=GREEN
//   LED=BLUE
//   LED=YELLOW
//   LED=CYAN
//   LED=MAGENTA
//   LED=WHITE
//   LED=RGB,255,128,0
//   LED=AUTO
//
// LED=OFF does not change the configured brightness or selected colour.
// LED=ON restores the previous normal LED state.
//
// Fault indication always overrides manual LED settings.

void processLEDCommand(String command)
{
  command.trim();

  String value =
    command.substring(4);

  value.trim();
  value.toUpperCase();

  // Automatic mode.
  if (value == "AUTO")
  {
    ledMode = LED_MODE_AUTO;
    ledEnabled = true;
    bootFullBrightness = false;

    Serial.println("ACK LED=AUTO");

    updateLED();

    return;
  }

  // Enable the LED without changing its selected colour or dim level.
  if (value == "ON")
  {
    ledEnabled = true;
    bootFullBrightness = false;

    Serial.printf(
      "ACK LED=ON DIM=%d\n",
      ledDimPercent
    );

    updateLED();

    return;
  }

  // Disable the LED without changing its configured dim level.
  if (value == "OFF")
  {
    ledEnabled = false;
    bootFullBrightness = false;

    updateLED();

    Serial.println("ACK LED=OFF");

    return;
  }

  // Set the normal LED brightness.
  //
  // Format:
  //   LED=DIM,50

  if (value.startsWith("DIM,"))
  {
    String dimString =
      value.substring(4);

    dimString.trim();

    int dim =
      dimString.toInt();

    if (
      dimString.length() == 0 ||
      dim < 0 ||
      dim > 100
    )
    {
      Serial.println(
        "ERROR: DIM must be between 0 and 100"
      );

      return;
    }

    ledDimPercent = dim;
    bootFullBrightness = false;

    Serial.printf(
      "ACK LED=DIM,%d\n",
      ledDimPercent
    );

    updateLED();

    return;
  }

  // Named colours.

  if (value == "RED")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 255;
    manualLEDGreen = 0;
    manualLEDBlue = 0;

    updateLED();

    Serial.println("ACK LED=RED");

    return;
  }

  if (value == "GREEN")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 0;
    manualLEDGreen = 255;
    manualLEDBlue = 0;

    updateLED();

    Serial.println("ACK LED=GREEN");

    return;
  }

  if (value == "BLUE")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 0;
    manualLEDGreen = 0;
    manualLEDBlue = 255;

    updateLED();

    Serial.println("ACK LED=BLUE");

    return;
  }

  if (value == "YELLOW")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 255;
    manualLEDGreen = 255;
    manualLEDBlue = 0;

    updateLED();

    Serial.println("ACK LED=YELLOW");

    return;
  }

  if (value == "CYAN")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 0;
    manualLEDGreen = 255;
    manualLEDBlue = 255;

    updateLED();

    Serial.println("ACK LED=CYAN");

    return;
  }

  if (value == "MAGENTA")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 255;
    manualLEDGreen = 0;
    manualLEDBlue = 255;

    updateLED();

    Serial.println("ACK LED=MAGENTA");

    return;
  }

  if (value == "WHITE")
  {
    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = 255;
    manualLEDGreen = 255;
    manualLEDBlue = 255;

    updateLED();

    Serial.println("ACK LED=WHITE");

    return;
  }

  // RGB colour.
  //
  // Format:
  //   LED=RGB,255,128,0

  if (value.startsWith("RGB,"))
  {
    String rgbValues =
      value.substring(4);

    int firstComma =
      rgbValues.indexOf(',');

    if (firstComma < 0)
    {
      Serial.println(
        "ERROR: RGB format is LED=RGB,R,G,B"
      );

      return;
    }

    int secondComma =
      rgbValues.indexOf(
        ',',
        firstComma + 1
      );

    if (secondComma < 0)
    {
      Serial.println(
        "ERROR: RGB format is LED=RGB,R,G,B"
      );

      return;
    }

    String redString =
      rgbValues.substring(
        0,
        firstComma
      );

    String greenString =
      rgbValues.substring(
        firstComma + 1,
        secondComma
      );

    String blueString =
      rgbValues.substring(
        secondComma + 1
      );

    redString.trim();
    greenString.trim();
    blueString.trim();

    int red =
      redString.toInt();

    int green =
      greenString.toInt();

    int blue =
      blueString.toInt();

    // Ensure all three RGB values are present.
    if (
      redString.length() == 0 ||
      greenString.length() == 0 ||
      blueString.length() == 0
    )
    {
      Serial.println(
        "ERROR: RGB values cannot be empty"
      );

      return;
    }

    if (
      red < 0 || red > 255 ||
      green < 0 || green > 255 ||
      blue < 0 || blue > 255
    )
    {
      Serial.println(
        "ERROR: RGB values must be between 0 and 255"
      );

      return;
    }

    ledMode = LED_MODE_MANUAL;
    ledEnabled = true;
    bootFullBrightness = false;

    manualLEDRed = red;
    manualLEDGreen = green;
    manualLEDBlue = blue;

    updateLED();

    Serial.printf(
      "ACK LED=RGB,%d,%d,%d\n",
      red,
      green,
      blue
    );

    return;
  }

  Serial.print(
    "ERROR: Unknown LED command: "
  );

  Serial.println(value);
}


// -----------------------------------------------------------------------------
// Process serial command
// -----------------------------------------------------------------------------
//
// Commands are received as newline-terminated text over USB serial.
//
// Supported telemetry commands:
//
//   CPU=0-100
//   RAM=0-100
//
// LED commands are handled separately by processLEDCommand().

void processCommand(String command)
{
  command.trim();

  if (command.length() == 0)
    return;

  if (command.startsWith("LED="))
  {
    processLEDCommand(command);
    return;
  }

  if (command.startsWith("CPU="))
  {
    String valueString =
      command.substring(4);

    float cpuValue =
      valueString.toFloat();

    if (
      cpuValue < 0.0f ||
      cpuValue > 100.0f
    )
    {
      Serial.println(
        "ERROR: CPU must be between 0 and 100"
      );

      return;
    }

    setCPU(cpuValue);
    return;
  }

  if (command.startsWith("RAM="))
  {
    String valueString =
      command.substring(4);

    float ramValue =
      valueString.toFloat();

    if (
      ramValue < 0.0f ||
      ramValue > 100.0f
    )
    {
      Serial.println(
        "ERROR: RAM must be between 0 and 100"
      );

      return;
    }

    setRAM(ramValue);
    return;
  }

  Serial.print(
    "ERROR: Unknown command: "
  );

  Serial.println(command);
}


// -----------------------------------------------------------------------------
// Setup
// -----------------------------------------------------------------------------

void setup()
{
  // Reduce CPU frequency to 40 MHz.
  setCpuFrequencyMhz(
    ESP32_CPU_FREQUENCY_MHZ
  );

  Serial.begin(115200);

  delay(1000);

  Serial.println();
  Serial.println("================================");
  Serial.println("ESP32-C3-Zero Gauge Controller");
  Serial.println("================================");
  Serial.println();

  Serial.println("USB protocol:");
  Serial.println("  CPU=0");
  Serial.println("  CPU=25");
  Serial.println("  CPU=50");
  Serial.println("  CPU=75");
  Serial.println("  CPU=100");
  Serial.println("  RAM=0");
  Serial.println("  RAM=25");
  Serial.println("  RAM=50");
  Serial.println("  RAM=75");
  Serial.println("  RAM=100");
  Serial.println();

  Serial.println("LED commands:");
  Serial.println("  LED=RED");
  Serial.println("  LED=GREEN");
  Serial.println("  LED=BLUE");
  Serial.println("  LED=YELLOW");
  Serial.println("  LED=CYAN");
  Serial.println("  LED=MAGENTA");
  Serial.println("  LED=WHITE");
  Serial.println("  LED=OFF");
  Serial.println("  LED=ON");
  Serial.println("  LED=DIM,50");
  Serial.println("  LED=RGB,255,128,0");
  Serial.println("  LED=AUTO");
  Serial.println();

  Serial.println("CPU gauge: GPIO7");
  Serial.println("RAM gauge: GPIO6");
  Serial.println("LED red: GPIO1");
  Serial.println("LED green: GPIO2");
  Serial.println("LED blue: GPIO0");
  Serial.println("LED common: shared ESP32 GND");
  Serial.println();

  Serial.println("LED default dim: 50%");
  Serial.println("LED boot brightness: 100%");
  Serial.println("LED fault brightness: 100%");
  Serial.println();

  Serial.println("PWM frequency: 500 Hz");
  Serial.println("CPU smoothing: 250 ms");
  Serial.println("RAM smoothing: 500 ms");
  Serial.println("Gauge update interval: 10 ms");
  Serial.println("CPU frequency: 40 MHz");
  Serial.println("Signal timeout: 3000 ms");
  Serial.println("Fault sweep period: 4000 ms");
  Serial.println();

  // Configure PWM for the two gauges.
  ledcAttach(
    CPU_GAUGE_PIN,
    PWM_FREQUENCY,
    PWM_RESOLUTION
  );

  ledcAttach(
    RAM_GAUGE_PIN,
    PWM_FREQUENCY,
    PWM_RESOLUTION
  );

  // Configure PWM for the RGB LED channels.
  ledcAttach(
    LED_RED_PIN,
    PWM_FREQUENCY,
    PWM_RESOLUTION
  );

  ledcAttach(
    LED_GREEN_PIN,
    PWM_FREQUENCY,
    PWM_RESOLUTION
  );

  ledcAttach(
    LED_BLUE_PIN,
    PWM_FREQUENCY,
    PWM_RESOLUTION
  );

  // Start in automatic LED mode at full brightness.
  ledMode = LED_MODE_AUTO;
  ledEnabled = true;

  bootFullBrightness = true;

  updateLED();

  // Initialise both gauges at zero.
  currentCPUGaugePercent = 0.0f;
  targetCPUGaugePercent = 0.0f;

  currentRAMGaugePercent = 0.0f;
  targetRAMGaugePercent = 0.0f;

  lastCPUPWM = -1;
  lastRAMPWM = -1;

  setGauge(
    CPU_GAUGE_PIN,
    0.0f,
    lastCPUPWM
  );

  setGauge(
    RAM_GAUGE_PIN,
    0.0f,
    lastRAMPWM
  );

  lastCPUUpdate = millis();
  lastRAMUpdate = millis();

  Serial.println("Ready.");
  Serial.println();
}


// -----------------------------------------------------------------------------
// Main loop
// -----------------------------------------------------------------------------

void loop()
{
  // Receive newline-terminated commands from the host.
  static String input = "";

  while (Serial.available())
  {
    char c = Serial.read();

    if (c == '\n' || c == '\r')
    {
      if (input.length() > 0)
      {
        processCommand(input);
        input = "";
      }
    }
    else
    {
      input += c;

      // Limit command length to prevent excessive memory use.
      if (input.length() > 100)
      {
        input = "";

        Serial.println(
          "ERROR: Command too long"
        );
      }
    }
  }

  // Monitor the telemetry connection.
  updateSignalStatus();

  // Update gauges according to the current operating state.
  if (signalFault)
  {
    updateFaultSweep();
  }
  else
  {
    updateCPUGauge();
    updateRAMGauge();
  }

  // Apply the current LED state.
  updateLED();

  // Allow the gauges to update at approximately 10 ms intervals while
  // avoiding unnecessary continuous CPU activity.
  delay(10);
}
