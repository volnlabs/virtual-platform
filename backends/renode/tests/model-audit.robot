*** Settings ***
Documentation    Installed-model and warning audit; no guest or RP1 qualification.
Library          OperatingSystem

*** Variables ***
${UNMAPPED_WARNING}    non existing peripheral

*** Test Cases ***
Inventory Loaded Peripheral Types
    ${types}=    Execute Command    python "from System import AppDomain; print('\\n'.join(sorted(t.FullName for a in AppDomain.CurrentDomain.GetAssemblies() if a.GetName().Name == 'Infrastructure' for t in a.GetTypes() if t.IsPublic and t.FullName.startswith('Antmicro.Renode.Peripherals.'))))"
    Create File    ${AUDIT_DIRECTORY}/peripheral-types.txt    ${types}
    Should Contain    ${types}    Antmicro.Renode.Peripherals.PCI.PCIeRootComplex

Unmapped Accesses Emit Warnings
    Execute Command    mach create
    Create Log Tester    0
    ${value}=    Execute Command    sysbus ReadDoubleWord 0x20000
    Should Be Equal As Integers    ${value}    0
    Wait For Log Entry    ReadDoubleWord from ${UNMAPPED_WARNING}    timeout=0
    Execute Command    sysbus WriteDoubleWord 0x20000 1
    Wait For Log Entry    WriteDoubleWord to ${UNMAPPED_WARNING}    timeout=0

Reserved PL011 Offset Is Silently Ignored
    Create UART Probe
    ${value}=    Execute Command    sysbus ReadDoubleWord 0x10040
    Should Be Equal As Integers    ${value}    0
    Execute Command    sysbus WriteDoubleWord 0x10040 1
    ${value}=    Execute Command    sysbus ReadDoubleWord 0x10040
    Should Be Equal As Integers    ${value}    0
    Should Not Be In Log    uart:    timeout=0

Unsupported Width And Control Bits Emit Warnings
    Create UART Probe
    Execute Command    sysbus ReadQuadWord 0x10000
    Wait For Log Entry    Attempted QuadWord read isn't supported    timeout=0
    Execute Command    sysbus WriteDoubleWord 0x10030 0xffffffff
    Wait For Log Entry    Unhandled bits:    timeout=0

*** Keywords ***
Create UART Probe
    Execute Command    mach create
    Execute Command    machine LoadPlatformDescriptionFromString "uart: UART.PL011 @ sysbus 0x10000"
    Create Log Tester    0
