*** Settings ***
Documentation    IO_BANK0 unit profile: conditioned digital samples and forced outputs; no pads, filters, RIO or PCIe delivery.
Test Setup       Create GPIO

*** Test Cases ***
Reset Leaves Outputs And Interrupts Disabled
    FOR    ${address}    IN    0x10004    0x100dc
        Register Should Equal    ${address}    0x9f
    END
    Register Should Equal    0x10000    0
    Register Should Equal    0x10100    0
    Register Should Equal    0x1011c    0
    Register Should Equal    0x10124    0
    Assert LED State    false
    State Should Contain    27    output=disabled

Forced Output Captures Do Not Invent Pad Loopback
    Execute Command    sysbus WriteDoubleWord 0x10004 0xe085
    Register Should Equal    0x10000    0x2000
    State Should Contain    0    output=low
    Execute Command    emulation RunFor "0.000001"
    Execute Command    sysbus WriteDoubleWord 0x12004 0x1000
    Register Should Equal    0x10000    0x2200
    State Should Contain    0    output=high
    Execute Command    sysbus WriteDoubleWord 0x10004 0xb085
    State Should Contain    0    output=disabled
    Wait For Log Entry    pattern=output=low    timeout=0
    Wait For Log Entry    pattern=output=high    timeout=0
    Wait For Log Entry    pattern=output=disabled    timeout=0

Edges Latch Independently Of Masks And Clear Without Changing Input
    Execute Command    sysbus.gpio OnGPIO 0 true
    Register Should Equal    0x10000    0x00a20000
    Register Should Equal    0x10100    0
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00208085
    Register Should Equal    0x10100    1
    Register Should Equal    0x10124    0
    Assert LED State    false
    Execute Command    sysbus WriteDoubleWord 0x1211c 1
    Register Should Equal    0x10124    1
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x12004 0x10000000
    Register Should Equal    0x10004    0x00208085
    Register Should Equal    0x10000    0x00820000
    Register Should Equal    0x10124    0
    Assert LED State    false
    Execute Command    sysbus.gpio OnGPIO 0 true
    Register Should Equal    0x10124    0
    Execute Command    sysbus.gpio OnGPIO 0 false
    Register Should Equal    0x10000    0x00500000
    Execute Command    sysbus WriteDoubleWord 0x12004 0x00100000
    Register Should Equal    0x10124    1
    Assert LED State    true

Live Level Survives Reset Pulse And Destination Masking
    Execute Command    sysbus.gpio OnGPIO 0 false
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00408085
    Execute Command    sysbus WriteDoubleWord 0x1211c 1
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x12004 0x10000000
    Register Should Equal    0x10000    0x30400000
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x1311c 1
    Register Should Equal    0x10100    1
    Register Should Equal    0x10124    0
    Assert LED State    false
    Execute Command    sysbus WriteDoubleWord 0x1211c 1
    Assert LED State    true
    Execute Command    sysbus.gpio OnGPIO 0 true
    Assert LED State    false

Aliases Read Normally And Reset Clear Alias Does Not Acknowledge
    Execute Command    sysbus.gpio OnGPIO 0 true
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00208085
    Execute Command    sysbus WriteDoubleWord 0x1311c 1
    Execute Command    sysbus WriteDoubleWord 0x1111c 1
    Assert LED State    true
    FOR    ${address}    IN    0x1111c    0x1211c    0x1311c
        Register Should Equal    ${address}    1
    END
    Execute Command    sysbus WriteDoubleWord 0x13004 0x10000000
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x11004 0x10000000
    Assert LED State    false
    Register Should Equal    0x12004    0x00208085
    Execute Command    sysbus.gpio OnGPIO 0 false
    Execute Command    sysbus.gpio OnGPIO 0 true
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x10004 0x10208085
    Assert LED State    false
    Register Should Equal    0x10004    0x00208085

Multiple Pins Retain Independent Edges And Reset Clears Active State
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x100dc 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x1211c 0x08000001
    Execute Command    sysbus.gpio OnGPIO 0 true
    Execute Command    sysbus.gpio OnGPIO 0 false
    Register Should Equal    0x10000    0x30700000
    Execute Command    sysbus.gpio OnGPIO 27 true
    Register Should Equal    0x10124    0x08000001
    Execute Command    sysbus WriteDoubleWord 0x12004 0x10000000
    Register Should Equal    0x10124    0x08000000
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x10004 0xf085
    Execute Command    sysbus.gpio Reset
    Register Should Equal    0x10000    0
    Register Should Equal    0x100d8    0
    Register Should Equal    0x10124    0
    State Should Contain    0    output=disabled
    Assert LED State    false

*** Keywords ***
Create GPIO
    Execute Command    include "${MODEL_FILE}"
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "gpio: GPIOPort.RP1_GPIO @ sysbus 0x10000 { IRQ -> irqLED@0 }; irqLED: Miscellaneous.LED @ gpio 0"
    Create LED Tester    sysbus.gpio.irqLED    defaultTimeout=0
    Create Log Tester    0

Register Should Equal
    [Arguments]    ${address}    ${expected}
    ${actual}=    Execute Command    sysbus ReadDoubleWord ${address}
    Should Be Equal As Integers    ${actual}    ${expected}

State Should Contain
    [Arguments]    ${pin}    ${expected}
    ${state}=    Execute Command    sysbus.gpio GetPinState ${pin}
    Should Contain    ${state}    ${expected}
