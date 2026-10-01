*** Settings ***
Documentation    IO_BANK0/RIO output unit profile: digital pad gating; no analog behavior, filters or PCIe delivery.
Test Setup       Create GPIO

*** Test Cases ***
Disabled Pad Input Suppresses External Edges
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x1211c 1
    Execute Command    sysbus.gpio OnGPIO 0 true
    Register Should Equal    0x10000    0x00400000
    Register Should Equal    0x10124    0
    Assert LED State    false

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
    FOR    ${address}    ${value}    IN    0x30004    0x9a    0x30024    0x9a    0x30028    0x96    0x30070    0x96
        Register Should Equal    ${address}    ${value}
    END
    State Should Contain    0    drive=disabled

Driver GPIO Function Selection Uses Reset RIO Source
    # Pinned driver order: function -> output -> enable -> pad OD/IE.
    Execute Command    sysbus WriteDoubleWord 0x10004 0x85
    Register Should Equal    0x10000    0
    State Should Contain    0    output=disabled
    Execute Command    sysbus WriteDoubleWord 0x10004 0x3085
    Register Should Equal    0x10000    0x200
    State Should Contain    0    output=disabled
    Execute Command    sysbus WriteDoubleWord 0x10004 0xf085
    Register Should Equal    0x10000    0x2200
    State Should Contain    0    output=high
    State Should Contain    0    drive=disabled
    Execute Command    sysbus WriteDoubleWord 0x30004 0x5a
    State Should Contain    0    drive=high
    Register Should Equal    0x10000    0x2200

RIO Aliases Feed Selected Pins Without Changing Input Or IRQ
    Register Should Equal    0x20000    0
    Register Should Equal    0x20004    0
    Execute Command    sysbus WriteDoubleWord 0x22000 0x08000001
    Execute Command    sysbus WriteDoubleWord 0x22004 0x08000001
    # RIO cannot drive a pin while NULL is selected.
    Register Should Equal    0x10000    0
    State Should Contain    0    output=disabled
    Execute Command    sysbus WriteDoubleWord 0x10004 0x85
    Execute Command    sysbus WriteDoubleWord 0x100dc 0x85
    Register Should Equal    0x10000    0x3300
    Register Should Equal    0x100d8    0x3300
    State Should Contain    0    output=high
    State Should Contain    27    output=high
    Register Should Equal    0x10100    0
    Assert LED State    false
    FOR    ${address}    IN    0x20000    0x21000    0x22000    0x23000
        Register Should Equal    ${address}    0x08000001
    END
    Execute Command    sysbus WriteDoubleWord 0x23000 1
    State Should Contain    0    output=low
    State Should Contain    27    output=high
    Execute Command    sysbus WriteDoubleWord 0x21004 0x08000000
    State Should Contain    27    output=disabled
    Register Should Equal    0x10004    0x85
    Register Should Equal    0x20000    0x08000000
    FOR    ${address}    IN    0x20004    0x21004    0x22004    0x23004
        Register Should Equal    ${address}    1
    END
    Execute Command    sysbus WriteDoubleWord 0x21000 1
    State Should Contain    0    output=high
    Execute Command    sysbus WriteDoubleWord 0x23004 1
    State Should Contain    0    output=disabled

Output And Enable Overrides Select Invert Or Force RIO Independently
    Execute Command    sysbus WriteDoubleWord 0x20000 1
    Execute Command    sysbus WriteDoubleWord 0x20004 1
    FOR    ${control}    ${status}    ${output}    IN
    ...    0x85      0x3300    high
    ...    0x1085    0x3100    low
    ...    0x4085    0x1300    disabled
    ...    0x5085    0x1100    disabled
    ...    0xe085    0x3100    low
    ...    0xb085    0x1300    disabled
        Execute Command    sysbus WriteDoubleWord 0x10004 ${control}
        Register Should Equal    0x10000    ${status}
        State Should Contain    0    output=${output}
    END
    Execute Command    sysbus WriteDoubleWord 0x10004 0x5085
    Execute Command    sysbus WriteDoubleWord 0x20000 0
    Execute Command    sysbus WriteDoubleWord 0x20004 0
    Register Should Equal    0x10000    0x2200
    State Should Contain    0    output=high
    # NULL's signal source stays zero independently of RIO registers.
    Execute Command    sysbus WriteDoubleWord 0x20000 1
    Execute Command    sysbus WriteDoubleWord 0x20004 1
    Execute Command    sysbus WriteDoubleWord 0x10004 0x509f
    Register Should Equal    0x10000    0x2200
    State Should Contain    0    output=high

Reset Clears Active RIO State In Both Register Windows
    Execute Command    sysbus WriteDoubleWord 0x10004 0x85
    Execute Command    sysbus WriteDoubleWord 0x20000 1
    Execute Command    sysbus WriteDoubleWord 0x20004 1
    State Should Contain    0    output=high
    Execute Command    sysbus.gpio OnGPIO 0 true
    Execute Command    sysbus.gpio Reset
    Register Should Equal    0x20000    0
    Register Should Equal    0x20004    0
    Register Should Equal    0x10004    0x9f
    Register Should Equal    0x10000    0
    Execute Command    sysbus WriteDoubleWord 0x10004 0x85
    State Should Contain    0    output=disabled
    Wait For Log Entry    pattern=cause=rio    timeout=0

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
    Execute Command    sysbus WriteDoubleWord 0x32004 0x40
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
    Execute Command    sysbus WriteDoubleWord 0x32004 0x40
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
    Execute Command    sysbus WriteDoubleWord 0x32004 0x40
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
    Execute Command    sysbus WriteDoubleWord 0x32004 0x40
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x100dc 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x1211c 0x08000001
    Execute Command    sysbus.gpio OnGPIO 0 true
    Execute Command    sysbus.gpio OnGPIO 0 false
    Register Should Equal    0x10000    0x30700000
    Execute Command    sysbus WriteDoubleWord 0x32070 0x40
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

Pad Disable Overrides RIO And Forced Enable Without Input Loopback
    Execute Command    sysbus WriteDoubleWord 0x10004 0x85
    Execute Command    sysbus WriteDoubleWord 0x20000 1
    Execute Command    sysbus WriteDoubleWord 0x20004 1
    State Should Contain    0    drive=disabled
    Execute Command    sysbus WriteDoubleWord 0x33004 0x80
    State Should Contain    0    drive=high
    Execute Command    sysbus WriteDoubleWord 0x23000 1
    State Should Contain    0    drive=low
    Execute Command    sysbus WriteDoubleWord 0x23004 1
    State Should Contain    0    drive=disabled
    Execute Command    sysbus WriteDoubleWord 0x10004 0xf085
    State Should Contain    0    drive=high
    Execute Command    sysbus WriteDoubleWord 0x32004 0x80
    State Should Contain    0    drive=disabled
    Register Should Equal    0x10000    0x2200
    Assert LED State    false
    Wait For Log Entry    pattern=drive=high    timeout=0
    Wait For Log Entry    pattern=cause=pads    timeout=0

Input Enable Resamples Held Input Using Explicit Unit Policy
    Execute Command    sysbus WriteDoubleWord 0x10004 0x00308085
    Execute Command    sysbus WriteDoubleWord 0x1211c 1
    Execute Command    sysbus.gpio OnGPIO 0 true
    Assert LED State    false
    Execute Command    sysbus WriteDoubleWord 0x32004 0x40
    Register Should Equal    0x10000    0x30a20000
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x12004 0x10000000
    Assert LED State    false
    Execute Command    sysbus WriteDoubleWord 0x33004 0x40
    Register Should Equal    0x10000    0x30500000
    Assert LED State    true
    Execute Command    sysbus WriteDoubleWord 0x12004 0x10000000
    Execute Command    sysbus.gpio OnGPIO 0 false
    Execute Command    sysbus.gpio OnGPIO 0 true
    Register Should Equal    0x10000    0x00400000
    Assert LED State    false
    # Input disable gates edges, not the sampled low-level condition.
    Execute Command    sysbus WriteDoubleWord 0x12004 0x00400000
    Assert LED State    true

Pad Aliases Are Isolated And Reset Restores Gates
    Execute Command    sysbus WriteDoubleWord 0x100dc 0xf085
    Execute Command    sysbus WriteDoubleWord 0x31070 0xc0
    FOR    ${address}    IN    0x30070    0x31070    0x32070    0x33070
        Register Should Equal    ${address}    0x56
    END
    Register Should Equal    0x30004    0x9a
    State Should Contain    27    drive=high
    Execute Command    sysbus.gpio OnGPIO 27 true
    State Should Contain    27    input=True
    # Pull/drive/slew/Schmitt fields are readback only, not an analog model.
    Execute Command    sysbus WriteDoubleWord 0x30004 0x7f
    Register Should Equal    0x30004    0x7f
    Register Should Equal    0x10000    0
    Execute Command    sysbus.gpio Reset
    Register Should Equal    0x30004    0x9a
    Register Should Equal    0x30070    0x96
    Register Should Equal    0x100d8    0
    State Should Contain    27    drive=disabled
    Execute Command    sysbus.gpio OnGPIO 27 true
    Register Should Equal    0x100d8    0x00400000

*** Keywords ***
Create GPIO
    Execute Command    include "${MODEL_FILE}"
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "gpio: GPIOPort.RP1_GPIO @ { sysbus 0x10000; sysbus new Bus.BusMultiRegistration { address: 0x20000; size: 0x4000; region: \\"rio\\" }; sysbus new Bus.BusMultiRegistration { address: 0x30000; size: 0x4000; region: \\"pads\\" } } { IRQ -> irqLED@0 }; irqLED: Miscellaneous.LED @ gpio 0"
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
