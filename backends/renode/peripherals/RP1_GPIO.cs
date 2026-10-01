// Isolated IO_BANK0, RIO output and digital pad gates. No analog behavior or PCIe.
// See docs/contracts/rp1-gpio-model.md for supported fields and sampling policy.
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.GPIOPort
{
    public class RP1_GPIO : SimpleContainer<IPeripheral>, IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IQuadWordPeripheral, IKnownSize, IGPIOReceiver
    {
        public RP1_GPIO(IMachine machine) : base(machine)
        {
            IRQ = new GPIO();
            Reset();
        }

        public long Size => 0x4000;
        public GPIO IRQ { get; private set; }
        public int CoverageFailures { get; private set; }

        public override void Reset()
        {
            pcieEnable = rioOutput = rioEnable = 0;
            for(var i = 0; i < PinCount; i++)
            {
                control[i] = 0x9f;
                pads[i] = i < 9 ? 0x9au : 0x96u;
                edges[i] = 0;
                input[i] = sampled[i] = externalInput[i] = false;
            }
            this.Log(LogLevel.Info, "RP1_GPIO_PROFILE exclusions=analog_pads,filtering,rio_input,alternate_mux,pcie_delivery rio_reset_preset=zero input_gate_policy=low_resample");
            Refresh("reset", true);
            // Reset must not erase unsupported-access evidence or reuse sequence numbers.
        }

        public void OnGPIO(int number, bool value)
        {
            CheckPin(number);
            externalInput[number] = value;
            SampleInput(number);
            Refresh("input");
        }

        private void SampleInput(int pin)
        {
            // Explicit unit policy: IE off samples low; changing IE resamples a
            // held external level. This does not model analog or synchronizer timing.
            var value = (pads[pin] & 0x40) != 0 && externalInput[pin];
            if(input[pin] != value) edges[pin] |= value ? 1u << 21 : 1u << 20;
            input[pin] = value;
            sampled[pin] = true;
        }

        public uint ReadDoubleWord(long offset)
        {
            CheckOffset(offset);
            offset &= 0xfff; // Atomic aliases read ordinary data, without side effects.
            if(offset < PinCount * 8)
            {
                var pin = (int)(offset / 8);
                return (offset & 4) != 0 ? control[pin] : Status(pin);
            }
            if(offset == 0x100) return rawInterrupts;
            if(offset == 0x11c) return pcieEnable;
            if(offset == 0x124) return rawInterrupts & pcieEnable;
            throw Unsupported(offset, "register");
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            CheckOffset(offset);
            var alias = (int)(offset / 0x1000);
            var register = offset & 0xfff;
            if(register == 0x11c)
            {
                if((value & ~0x0fffffffu) != 0) throw Unsupported(offset, "destination bits");
                pcieEnable = ApplyAlias(pcieEnable, value, alias);
            }
            else if(register < PinCount * 8 && (register & 4) != 0)
            {
                var pin = (int)(register / 8);
                // Reject unexplained write bits even when a clear alias would hide them.
                if((value & ~0x10f0ffffu) != 0) throw Unsupported(offset, "control bits");
                var next = ApplyAlias(control[pin], value, alias);
                ValidateControl(offset, next);
                control[pin] = next & ~(1u << 28);
                if((next & (1u << 28)) != 0) edges[pin] = 0;
            }
            else throw Unsupported(offset, "register/read-only write");
            Refresh("write");
        }

        [ConnectionRegion("rio")]
        public uint ReadRioDoubleWord(long offset)
        {
            CheckOffset(offset);
            switch(offset & 0xfff)
            {
                case 0: return rioOutput;
                case 4: return rioEnable;
                default: throw Unsupported(offset, "RIO register/input path");
            }
        }

        [ConnectionRegion("rio")]
        public void WriteRioDoubleWord(long offset, uint value)
        {
            CheckOffset(offset);
            if((value & ~0x0fffffffu) != 0) throw Unsupported(offset, "RIO pin bits");
            var alias = (int)(offset / 0x1000);
            switch(offset & 0xfff)
            {
                case 0: rioOutput = ApplyAlias(rioOutput, value, alias); break;
                case 4: rioEnable = ApplyAlias(rioEnable, value, alias); break;
                default: throw Unsupported(offset, "RIO register/input path");
            }
            Refresh("rio");
        }

        [ConnectionRegion("pads")]
        public uint ReadPadDoubleWord(long offset) => pads[PadPin(offset)];

        [ConnectionRegion("pads")]
        public void WritePadDoubleWord(long offset, uint value)
        {
            var pin = PadPin(offset);
            if((value & ~0xffu) != 0) throw Unsupported(offset, "pad bits");
            pads[pin] = ApplyAlias(pads[pin], value, (int)(offset / 0x1000));
            if(sampled[pin]) SampleInput(pin);
            Refresh("pads");
        }

        private int PadPin(long offset)
        {
            CheckOffset(offset);
            var register = offset & 0xfff;
            if(register < 4 || register > PinCount * 4) throw Unsupported(offset, "pad register");
            return (int)(register / 4) - 1;
        }

        // Named regions do not inherit default bus-interface width handlers.
        [ConnectionRegion("rio")]
        public byte ReadByte(long offset) { throw Unsupported(offset, "8-bit read"); }
        [ConnectionRegion("rio")]
        public ushort ReadWord(long offset) { throw Unsupported(offset, "16-bit read"); }
        [ConnectionRegion("rio")]
        public ulong ReadQuadWord(long offset) { throw Unsupported(offset, "64-bit read"); }
        [ConnectionRegion("rio")]
        public void WriteByte(long offset, byte value) { throw Unsupported(offset, "8-bit write"); }
        [ConnectionRegion("rio")]
        public void WriteWord(long offset, ushort value) { throw Unsupported(offset, "16-bit write"); }
        [ConnectionRegion("rio")]
        public void WriteQuadWord(long offset, ulong value) { throw Unsupported(offset, "64-bit write"); }

        [ConnectionRegion("pads")]
        public byte ReadPadByte(long offset) => ReadByte(offset);
        [ConnectionRegion("pads")]
        public ushort ReadPadWord(long offset) => ReadWord(offset);
        [ConnectionRegion("pads")]
        public ulong ReadPadQuadWord(long offset) => ReadQuadWord(offset);
        [ConnectionRegion("pads")]
        public void WritePadByte(long offset, byte value) => WriteByte(offset, value);
        [ConnectionRegion("pads")]
        public void WritePadWord(long offset, ushort value) => WriteWord(offset, value);
        [ConnectionRegion("pads")]
        public void WritePadQuadWord(long offset, ulong value) => WriteQuadWord(offset, value);

        public string GetPinState(int pin)
        {
            CheckPin(pin);
            var output = !OutputEnabled(pin) ? "disabled" : OutputHigh(pin) ? "high" : "low";
            var drive = (pads[pin] & 0x80) != 0 ? "disabled" : output;
            return string.Format("pin={0} sampled={1} input={2} output={3} events=0x{4:X8} pending={5} drive={6} pad=0x{7:X2} external={8}",
                pin, sampled[pin], input[pin], output, Events(pin),
                ((rawInterrupts & pcieEnable) & (1u << pin)) != 0, drive, pads[pin], externalInput[pin]);
        }

        private void ValidateControl(long offset, uint value)
        {
            var function = value & 0x1f;
            if(function != 5 && function != 31) throw Unsupported(offset, "function mux");
            if((value & 0xfe0) != 0x80) throw Unsupported(offset, "filter time constant");
        }

        private uint Status(int pin)
        {
            var status = Events(pin);
            if(input[pin]) status |= 1u << 17;
            if(PeripheralSignal(pin, rioOutput)) status |= 1u << 8;
            if(PeripheralSignal(pin, rioEnable)) status |= 1u << 12;
            if(OutputHigh(pin)) status |= 1u << 9;
            if(OutputEnabled(pin)) status |= 1u << 13;
            if((rawInterrupts & (1u << pin)) != 0) status |= 3u << 28;
            return status;
        }

        private uint Events(int pin)
        {
            return edges[pin] | (sampled[pin] ? (input[pin] ? 1u << 23 : 1u << 22) : 0);
        }

        private bool PeripheralSignal(int pin, uint rio) => (control[pin] & 0x1f) == 5 && (rio & (1u << pin)) != 0;
        private bool OutputEnabled(int pin) => Override(PeripheralSignal(pin, rioEnable), (control[pin] >> 14) & 3);
        private bool OutputHigh(int pin) => Override(PeripheralSignal(pin, rioOutput), (control[pin] >> 12) & 3);

        private static bool Override(bool signal, uint selection)
        {
            switch(selection)
            {
                case 0: return signal;
                case 1: return !signal;
                case 2: return false;
                default: return true;
            }
        }

        private void Refresh(string cause, bool force = false)
        {
            rawInterrupts = 0;
            for(var i = 0; i < PinCount; i++)
            {
                if((Events(i) & control[i] & 0x00f00000) != 0) rawInterrupts |= 1u << i;
            }
            IRQ.Set((rawInterrupts & pcieEnable) != 0);
            for(var i = 0; i < PinCount; i++)
            {
                var state = GetPinState(i);
                if(force || state != lastCapture[i])
                {
                    lastCapture[i] = state;
                    this.Log(LogLevel.Info, "RP1_GPIO_STATE sequence={0} virtual_time={1} cause={2} {3}",
                        sequence++, machine.ElapsedVirtualTime.TimeElapsed, cause, state);
                }
            }
        }

        private static uint ApplyAlias(uint current, uint value, int alias)
        {
            switch(alias)
            {
                case 1: return current ^ value;
                case 2: return current | value;
                case 3: return current & ~value;
                default: return value;
            }
        }

        private void CheckOffset(long offset)
        {
            if(offset < 0 || offset >= Size || (offset & 3) != 0)
                throw Unsupported(offset, "offset/alignment");
        }

        private void CheckPin(int pin)
        {
            if(pin < 0 || pin >= PinCount) throw Unsupported(pin, "pin index");
        }

        private RecoverableException Unsupported(long offset, string reason)
        {
            CoverageFailures++;
            var message = string.Format("RP1_GPIO_UNSUPPORTED offset=0x{0:X} reason={1}", offset, reason);
            this.Log(LogLevel.Error, message);
            return new RecoverableException(message);
        }

        private const int PinCount = 28;
        private readonly uint[] control = new uint[PinCount], edges = new uint[PinCount], pads = new uint[PinCount];
        private readonly bool[] input = new bool[PinCount], sampled = new bool[PinCount], externalInput = new bool[PinCount];
        private readonly string[] lastCapture = new string[PinCount];
        private uint pcieEnable, rawInterrupts, rioOutput, rioEnable;
        private ulong sequence;
    }
}
