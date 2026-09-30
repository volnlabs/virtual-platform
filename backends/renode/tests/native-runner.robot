*** Settings ***
Documentation    Adapter integration check only; does not load or qualify a guest.
Library          OperatingSystem

*** Test Cases ***
Staged Inputs And Native Assertions Are Available
    File Should Exist    ${AXIOMOS_KERNEL}
    File Should Exist    ${VOLN_VP_DTB}
    File Should Exist    ${VOLN_VP_BOOT_SCRIPT}
    Should Be Equal    ${AXIOMOS_KERNEL}    ${VOLN_VP_RUN_DIR}/inputs/kernel.elf
    ${help}=    Execute Command    help
    ${expected}=    Get Environment Variable    VOLN_VP_SELFTEST_EXPECTED    Available commands:
    Should Contain    ${help}    ${expected}
