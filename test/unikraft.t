Tests some simple unikernels with qemu
  $ export arch=$(uname -m)
  $ qemu-system-$arch -cpu host --enable-kvm -nographic -nodefaults -serial stdio -m 32M -kernel sleep.exe > out.log
  $ tail -n2 out.log
  Hello
  World
  $ qemu-system-$arch -cpu host --enable-kvm -nographic -nodefaults -serial stdio -m 32M -kernel schedule.exe > out.log
  $ tail -n2 out.log
  Hello
  World
  $ chmod +w simple.txt
  $ qemu-system-$arch -cpu host --enable-kvm -nographic -nodefaults -serial stdio -m 32M -kernel block.exe -drive file=simple.txt,if=virtio,id=simple,format=raw > out.log
  $ tail -n2 out.log
  00000000: 94a3b2375dd8aa75e3d2cdef54179909
  00000200: 5e00b6c8f387deac083b9718e08a361b
