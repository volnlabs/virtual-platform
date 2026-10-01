*** Settings ***
Documentation    Expected-invalid MMIO unit probes. Native assertions pass; strict adapter must reject the error logs.
Test Setup       Create PWM

*** Test Cases ***
Unimplemented Offsets And Aliases Fail
    FOR    ${offset}    IN    0x04    0x1c    0x54    0x1000    0x2000    0x3000
        Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus.pwm ReadDoubleWord ${offset}
        Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus.pwm WriteDoubleWord ${offset} 0
    END

Widths And Alignment Fail Through The Bus
    FOR    ${width}    IN    Byte    Word    QuadWord
        Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus Read${width} 0x10000
        Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus Write${width} 0x10000 0
    END
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus ReadDoubleWord 0x10001
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10001 0

Unsupported Bits Do Not Change Registers
    FOR    ${value}    IN    2    0x10    0x20    0x40    0x200
        Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10014 ${value}
        ${control}=    Execute Command    sysbus ReadDoubleWord 0x10014
        Should Be Equal As Integers    ${control}    0x100
    END
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10000 0x10
    ${global}=    Execute Command    sysbus ReadDoubleWord 0x10000
    Should Be Equal As Integers    ${global}    0

Zero Range Cannot Start A Trailing Edge Channel
    Execute Command    sysbus WriteDoubleWord 0x10014 0x101
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    ${global}=    Execute Command    sysbus ReadDoubleWord 0x10000
    Should Be Equal As Integers    ${global}    0
    Execute Command    sysbus.pwm Reset
    ${failures}=    Execute Command    sysbus.pwm CoverageFailures
    Should Be Equal As Integers    ${failures}    1

Queued Activation Cannot Lose Its Range
    Execute Command    sysbus WriteDoubleWord 0x10014 0x101
    Execute Command    sysbus WriteDoubleWord 0x10018 10
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10018 0
    Execute Command    emulation RunFor "0.000001"
    ${state}=    Execute Command    sysbus.pwm GetChannelState 0
    Should Contain    ${state}    enabled=True period=10

Queued Constant Output Cannot Become Zero Range PWM
    Execute Command    sysbus WriteDoubleWord 0x10000 0x80000001
    Run Keyword And Expect Error    *RP1_PWM_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10014 0x101
    ${control}=    Execute Command    sysbus ReadDoubleWord 0x10014
    Should Be Equal As Integers    ${control}    0x100

*** Keywords ***
Create PWM
    Execute Command    include "${MODEL_FILE}"
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "pwm: PWM.RP1_PWM @ sysbus 0x10000 { frequency: 1000000 }"
