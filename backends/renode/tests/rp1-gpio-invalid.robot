*** Settings ***
Documentation    Expected-invalid IO_BANK0 probes; Error logs must fail an adapter run even when these assertions pass.
Test Setup       Create GPIO

*** Test Cases ***
Unknown Registers And Read Only Writes Fail
    FOR    ${offset}    IN    0xe0    0x104    0x120    0x128
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus.gpio ReadDoubleWord ${offset}
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus.gpio WriteDoubleWord ${offset} 0
    END
    FOR    ${offset}    IN    0    0x100    0x124    0x2000    0x2124
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus.gpio WriteDoubleWord ${offset} 0
    END

Unsupported Fields Cannot Mutate Control Or Clear Events
    Execute Command    sysbus.gpio OnGPIO 0 true
    FOR    ${value}    IN    0x80    0x85    0x0100009f    0x0001009f    0x4000009f    0x0000001f    0x3000009f
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10004 ${value}
        ${control}=    Execute Command    sysbus ReadDoubleWord 0x10004
        Should Be Equal As Integers    ${control}    0x9f
        ${status}=    Execute Command    sysbus ReadDoubleWord 0x10000
        Should Be Equal As Integers    ${status}    0x00a20000
    END
    FOR    ${address}    IN    0x11004    0x12004    0x13004
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord ${address} 0x30000000
        ${control}=    Execute Command    sysbus ReadDoubleWord 0x10004
        Should Be Equal As Integers    ${control}    0x9f
        ${status}=    Execute Command    sysbus ReadDoubleWord 0x10000
        Should Be Equal As Integers    ${status}    0x00a20000
    END
    Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x1211c 0x10000001
    ${enable}=    Execute Command    sysbus ReadDoubleWord 0x1011c
    Should Be Equal As Integers    ${enable}    0

Widths Alignment And Invalid Pins Fail Without Erasing Evidence
    FOR    ${width}    IN    Byte    Word    QuadWord
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus Read${width} 0x10004
        Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus Write${width} 0x10004 0
    END
    Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus ReadDoubleWord 0x10001
    Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus WriteDoubleWord 0x10001 0
    Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus.gpio OnGPIO 28 true
    Run Keyword And Expect Error    *RP1_GPIO_UNSUPPORTED*    Execute Command    sysbus.gpio OnGPIO -1 true
    ${before}=    Execute Command    sysbus.gpio CoverageFailures
    Execute Command    sysbus.gpio Reset
    ${after}=    Execute Command    sysbus.gpio CoverageFailures
    Should Be Equal As Integers    ${before}    10
    Should Be Equal As Integers    ${after}    ${before}

*** Keywords ***
Create GPIO
    Execute Command    include "${MODEL_FILE}"
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "gpio: GPIOPort.RP1_GPIO @ sysbus 0x10000"
