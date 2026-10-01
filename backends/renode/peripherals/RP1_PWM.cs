// Unit-model profile: explicit external clock; no PCIe, CLOCKS, pads or FIFO.
// See docs/contracts/rp1-pwm-model.md for timing assumptions and coverage limits.
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.PWM
{
    public class RP1_PWM : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IQuadWordPeripheral, IKnownSize
    {
        public RP1_PWM(IMachine machine, long frequency)
        {
            if(frequency <= 0)
            {
                throw new RecoverableException("RP1_PWM requires a positive external clock frequency");
            }
            this.machine = machine;
            this.frequency = frequency;
            update = new LimitTimer(machine.ClockSource, (ulong)frequency, this, "update", limit: 1,
                direction: Direction.Ascending, enabled: false, eventEnabled: true, workMode: WorkMode.OneShot);
            update.LimitReached += ApplyControl;
            for(var i = 0; i < 4; i++)
            {
                var channel = i;
                periods[i] = new LimitTimer(machine.ClockSource, (ulong)frequency, this, "channel" + i, limit: 1,
                    direction: Direction.Ascending, enabled: false, eventEnabled: true, workMode: WorkMode.Periodic);
                periods[i].LimitReached += () => Overflow(channel);
            }
            Reset();
        }

        public long Size => 0x4000;
        public int CoverageFailures { get; private set; }

        public void Reset()
        {
            update.Reset();
            global = 0;
            for(var i = 0; i < 4; i++)
            {
                periods[i].Reset();
                control[i] = activeControl[i] = 0x100;
                range[i] = duty[i] = activeRange[i] = activeDuty[i] = 0;
                enabled[i] = false;
                Capture(i, "reset", true);
            }
            // CoverageFailures and the capture sequence survive reset: reset
            // must not erase evidence of an unsupported operation.
        }

        public uint ReadDoubleWord(long offset)
        {
            CheckAlignment(offset);
            if(offset == 0) return global;
            int channel, field;
            Decode(offset, out channel, out field);
            return field == 0 ? control[channel] : field == 4 ? range[channel] : duty[channel];
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            CheckAlignment(offset);
            if(offset == 0)
            {
                if((value & ~0x8000000Fu) != 0) throw Unsupported(offset, "global bits");
                for(var i = 0; i < 4; i++)
                {
                    if((value & (1u << i)) != 0 && (control[i] & 7) == 1 && range[i] == 0)
                        throw Unsupported(offset, "zero-range activation");
                }
                global = (value & 0xF) | (global & 0x80000000u) | (value & 0x80000000u);
                if((value & 0x80000000u) != 0 && !update.Enabled)
                {
                    update.Value = 0;
                    update.Enabled = true;
                }
                return;
            }
            int channel, field;
            Decode(offset, out channel, out field);
            if(field == 0)
            {
                // Only constant-zero and trailing-edge modes, optional inversion.
                // FIFO_POP_MASK is retained but has no effect without USEFIFO.
                if((value & ~0x109u) != 0) throw Unsupported(offset, "channel mode/bits");
                if(PendingEnable(channel) && (value & 7) == 1 && range[channel] == 0)
                    throw Unsupported(offset, "zero range during queued activation");
                control[channel] = value;
            }
            else if(field == 4)
            {
                if(value == 0 && ((enabled[channel] && (activeControl[channel] & 7) == 1)
                    || (PendingEnable(channel) && (control[channel] & 7) == 1)))
                    throw Unsupported(offset, "zero range while running or queued");
                range[channel] = value;
            }
            else duty[channel] = value;
        }

        public byte ReadByte(long offset) { throw Unsupported(offset, "8-bit read"); }
        public ushort ReadWord(long offset) { throw Unsupported(offset, "16-bit read"); }
        public ulong ReadQuadWord(long offset) { throw Unsupported(offset, "64-bit read"); }
        public void WriteByte(long offset, byte value) { throw Unsupported(offset, "8-bit write"); }
        public void WriteWord(long offset, ushort value) { throw Unsupported(offset, "16-bit write"); }
        public void WriteQuadWord(long offset, ulong value) { throw Unsupported(offset, "64-bit write"); }

        public string GetChannelState(int channel)
        {
            if(channel < 0 || channel >= 4) throw new RecoverableException("PWM channel must be 0..3");
            var inverted = (activeControl[channel] & 8) != 0;
            var output = "disabled";
            if(enabled[channel])
            {
                var high = (activeControl[channel] & 7) == 1 && activeDuty[channel] != 0;
                var pulsing = high && activeDuty[channel] < activeRange[channel];
                output = pulsing ? "pwm" : high != inverted ? "high" : "low";
            }
            return string.Format("channel={0} enabled={1} period={2} duty={3} invert={4} output={5} mode={6}",
                channel, enabled[channel], activeRange[channel], activeDuty[channel], inverted, output,
                activeControl[channel] & 7);
        }

        private void ApplyControl()
        {
            global &= 0xF;
            for(var i = 0; i < 4; i++)
            {
                var running = enabled[i] && (activeControl[i] & 7) == 1;
                activeControl[i] = control[i];
                enabled[i] = (global & (1u << i)) != 0;
                var start = enabled[i] && (activeControl[i] & 7) == 1;
                if(start && !running)
                {
                    // Profile policy: activation starts a period and consumes
                    // values written while stopped. Not a measured silicon delay.
                    activeRange[i] = range[i];
                    activeDuty[i] = duty[i];
                    periods[i].Limit = activeRange[i];
                    periods[i].Value = 0;
                }
                periods[i].Enabled = start;
                Capture(i, "update");
            }
        }

        private bool PendingEnable(int channel)
        {
            return (global & 0x80000000u) != 0 && (global & (1u << channel)) != 0;
        }

        private void Overflow(int channel)
        {
            activeRange[channel] = range[channel];
            activeDuty[channel] = duty[channel];
            periods[channel].Limit = activeRange[channel];
            periods[channel].Value = 0;
            Capture(channel, "overflow");
        }

        private void Capture(int channel, string cause, bool force = false)
        {
            var state = GetChannelState(channel);
            if(force || state != lastCapture[channel])
            {
                lastCapture[channel] = state;
                // Stream to native retained logs; no growing in-model event buffer.
                this.Log(LogLevel.Info, "RP1_PWM_STATE sequence={0} virtual_time={1} frequency_hz={2} cause={3} {4}",
                    sequence++, machine.ElapsedVirtualTime.TimeElapsed, frequency, cause, state);
            }
        }

        private void CheckAlignment(long offset)
        {
            if(offset < 0 || offset >= Size || (offset & 3) != 0)
                throw Unsupported(offset, "offset/alignment");
        }

        private void Decode(long offset, out int channel, out int field)
        {
            channel = (int)((offset - 0x14) / 0x10);
            field = (int)((offset - 0x14) % 0x10);
            if(offset < 0x14 || offset > 0x50 || (field != 0 && field != 4 && field != 12))
                throw Unsupported(offset, "register/alias");
        }

        private RecoverableException Unsupported(long offset, string reason)
        {
            CoverageFailures++;
            var message = string.Format("RP1_PWM_UNSUPPORTED offset=0x{0:X} reason={1}", offset, reason);
            this.Log(LogLevel.Error, message);
            return new RecoverableException(message);
        }

        private readonly IMachine machine;
        private readonly long frequency;
        private readonly LimitTimer update;
        private readonly LimitTimer[] periods = new LimitTimer[4];
        private readonly uint[] control = new uint[4], range = new uint[4], duty = new uint[4];
        private readonly uint[] activeControl = new uint[4], activeRange = new uint[4], activeDuty = new uint[4];
        private readonly bool[] enabled = new bool[4];
        private readonly string[] lastCapture = new string[4];
        private uint global;
        private ulong sequence;
    }
}
