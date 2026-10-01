*** Settings ***
Documentation    PWM model unit tests; explicit 1 MHz test clock, no guest, pads or PCIe.
Test Setup       Create PWM

*** Test Cases ***
Reset And Register Readback
    ${global}=    Execute Command    sysbus ReadDoubleWord 0x10000
    Should Be Equal As Integers    ${global}    0
    FOR    ${offset}    IN    0x14    0x24    0x34    0x44
        ${control}=    Execute Command    sysbus.pwm ReadDoubleWord ${offset}
        Should Be Equal As Integers    ${control}    0x100
    END
    State Should Contain    0    enabled=False period=0 duty=0 invert=False output=disabled

Enable Applies On A PWM Clock Edge
    Program Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    State Should Contain    0    enabled=False
    ${pending}=    Execute Command    sysbus ReadDoubleWord 0x10000
    Should Be Equal As Integers    ${pending}    0x80000001
    Execute Command    emulation RunFor "0.000001"
    ${settled}=    Execute Command    sysbus ReadDoubleWord 0x10000
    Should Be Equal As Integers    ${settled}    1
    State Should Contain    0    enabled=True period=10 duty=4 invert=False output=pwm

Duty And Range Wait For Overflow Despite Set Update
    Start Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10018 20
    Execute Command    sysbus WriteDoubleWord 0x10020 0
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Execute Command    emulation RunFor "0.000001"
    State Should Contain    0    period=10 duty=4
    Execute Command    emulation RunFor "0.000008"
    State Should Contain    0    period=10 duty=4
    Execute Command    emulation RunFor "0.000001"
    State Should Contain    0    enabled=True period=20 duty=0 invert=False output=low

Polarity Disable And Reset Are Captured
    Start Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10020 0
    Execute Command    emulation RunFor "0.000010"
    Execute Command    sysbus WriteDoubleWord 0x10014 0x109
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Execute Command    emulation RunFor "0.000001"
    State Should Contain    0    invert=True output=high
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000000
    Execute Command    emulation RunFor "0.000001"
    State Should Contain    0    enabled=False
    Wait For Log Entry    pattern=output=pwm    timeout=0
    Wait For Log Entry    pattern=output=low    timeout=0
    Wait For Log Entry    pattern=output=high    timeout=0
    Wait For Log Entry    pattern=output=disabled    timeout=0
    Start Channel Zero
    Execute Command    sysbus.pwm Reset
    Execute Command    emulation RunFor "0.000020"
    State Should Contain    0    enabled=False period=0 duty=0 invert=False output=disabled

Channels Have Independent Periods
    Program Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10024 0x101
    Execute Command    sysbus WriteDoubleWord 0x10028 5
    Execute Command    sysbus WriteDoubleWord 0x10030 5
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000003
    Execute Command    emulation RunFor "0.000001"
    State Should Contain    1    enabled=True period=5 duty=5 invert=False output=high
    Execute Command    sysbus WriteDoubleWord 0x10020 0
    Execute Command    sysbus WriteDoubleWord 0x10030 0
    Execute Command    emulation RunFor "0.000005"
    State Should Contain    0    period=10 duty=4
    State Should Contain    1    period=5 duty=0

Mode Changes Are Captured When Output Stays Low
    Start Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10020 0
    Execute Command    emulation RunFor "0.000010"
    Execute Command    sysbus WriteDoubleWord 0x10014 0x100
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Execute Command    emulation RunFor "0.000001"
    Wait For Log Entry    pattern=output=low mode=0    timeout=0

*** Keywords ***
Create PWM
    Execute Command    include "${MODEL_FILE}"
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "pwm: PWM.RP1_PWM @ sysbus 0x10000 { frequency: 1000000 }"
    Create Log Tester    0

Program Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10014 0x101
    Execute Command    sysbus WriteDoubleWord 0x10018 10
    Execute Command    sysbus WriteDoubleWord 0x10020 4

Start Channel Zero
    Program Channel Zero
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Execute Command    emulation RunFor "0.000001"

State Should Contain
    [Arguments]    ${channel}    ${expected}
    ${state}=    Execute Command    sysbus.pwm GetChannelState ${channel}
    Should Contain    ${state}    ${expected}
