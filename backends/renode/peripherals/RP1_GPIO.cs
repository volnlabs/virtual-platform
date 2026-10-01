// Isolated IO_BANK0 subset. No pads, filtering, peripheral mux or PCIe delivery.
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
            pcieEnable = 0;
            for(var i = 0; i < PinCount; i++)
            {
                control[i] = 0x9f;
                edges[i] = 0;
                input[i] = sampled[i] = false;
            }
            this.Log(LogLevel.Info, "RP1_GPIO_PROFILE exclusions=pads,filtering,peripheral_mux,pcie_delivery");
            Refresh("reset", true);
            // Reset must not erase unsupported-access evidence or reuse sequence numbers.
        }

        public void OnGPIO(int number, bool value)
        {
            CheckPin(number);
            // Samples are already conditioned by the external fixture. No implicit
            // output loopback, synchronizer latency, pull or electrical model.
            if(input[number] != value) edges[number] |= value ? 1u << 21 : 1u << 20;
            input[number] = value;
            sampled[number] = true;
            Refresh("input");
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

        public byte ReadByte(long offset) { throw Unsupported(offset, "8-bit read"); }
        public ushort ReadWord(long offset) { throw Unsupported(offset, "16-bit read"); }
        public ulong ReadQuadWord(long offset) { throw Unsupported(offset, "64-bit read"); }
        public void WriteByte(long offset, byte value) { throw Unsupported(offset, "8-bit write"); }
        public void WriteWord(long offset, ushort value) { throw Unsupported(offset, "16-bit write"); }
        public void WriteQuadWord(long offset, ulong value) { throw Unsupported(offset, "64-bit write"); }

        public string GetPinState(int pin)
        {
            CheckPin(pin);
            var output = !OutputEnabled(pin) ? "disabled" : OutputHigh(pin) ? "high" : "low";
            return string.Format("pin={0} sampled={1} input={2} output={3} events=0x{4:X8} pending={5}",
                pin, sampled[pin], input[pin], output, Events(pin),
                ((rawInterrupts & pcieEnable) & (1u << pin)) != 0);
        }

        private void ValidateControl(long offset, uint value)
        {
            var function = value & 0x1f;
            var output = (value >> 12) & 3;
            var enable = (value >> 14) & 3;
            if(function != 5 && function != 31) throw Unsupported(offset, "function mux");
            if((value & 0xfe0) != 0x80) throw Unsupported(offset, "filter time constant");
            // GPIO/RIO and alternate peripheral signal sources are not connected.
            // Accept only forced OE/data, or disabled NULL's reset signal source.
            if(enable == 1 || (enable == 0 && function != 31) || output == 1
                || (enable == 3 && output < 2))
                throw Unsupported(offset, "peripheral-derived output/enable");
        }

        private uint Status(int pin)
        {
            var status = Events(pin);
            if(input[pin]) status |= 1u << 17;
            if(OutputHigh(pin)) status |= 1u << 9;
            if(OutputEnabled(pin)) status |= 1u << 13;
            if((rawInterrupts & (1u << pin)) != 0) status |= 3u << 28;
            return status;
        }

        private uint Events(int pin)
        {
            return edges[pin] | (sampled[pin] ? (input[pin] ? 1u << 23 : 1u << 22) : 0);
        }

        private bool OutputEnabled(int pin) => ((control[pin] >> 14) & 3) == 3;
        private bool OutputHigh(int pin) => ((control[pin] >> 12) & 3) == 3;

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
        private readonly uint[] control = new uint[PinCount], edges = new uint[PinCount];
        private readonly bool[] input = new bool[PinCount], sampled = new bool[PinCount];
        private readonly string[] lastCapture = new string[PinCount];
        private uint pcieEnable, rawInterrupts;
        private ulong sequence;
    }
}
