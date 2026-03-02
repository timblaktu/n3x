# ISAR Artifact Hashes - Mutable state mapping unique filenames to SHA256 hashes
#
# This is the ONLY file modified by the isar-build-all script.
# Each key is a unique artifact filename (from build-matrix.nix mkArtifactName),
# and each value is the base32-encoded SHA256 hash.
#
# To update: nix run '.#isar-build-all' -- --variant <id>
# To add manually: nix-hash --type sha256 --flat --base32 <artifact-path>
#
# Extracted from backends/debian/debian-artifacts.nix (commit baseline)
{
  # =========================================================================
  # qemuamd64 - base
  # =========================================================================
  "isar-base-qemuamd64.wic" = "04msdl5d14rjgn0c3sscg8kxxarfs550ba81hb2s4d4zlgv9v8mn";
  "isar-base-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-base-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - base-swupdate
  # =========================================================================
  "isar-base-swupdate-qemuamd64.wic" = "1mlrlb5lidw19g92lw0bdxz7640l5zvr53as8hvzv5dk6mq3s6cq";
  "isar-base-swupdate-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-base-swupdate-qemuamd64-initrd.img" = "1v1gyjz71c70x9b2qppvw2wq8xmr4xq5dglf95flgcmccmy68qgp";

  # =========================================================================
  # qemuamd64 - agent
  # =========================================================================
  "isar-agent-qemuamd64.wic" = "100xmr555y1igwyijyyhbn1xj575ynillkny3rp0bpyxiz5j6ccn";
  "isar-agent-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-agent-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-simple-server-1
  # =========================================================================
  "isar-server-simple-server-1-qemuamd64.wic" = "0szpm5bxljdp58f2v1gpbyy0ga71f7zgmnccm2q91079354v7wa5";
  "isar-server-simple-server-1-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-simple-server-1-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-simple-server-2
  # =========================================================================
  "isar-server-simple-server-2-qemuamd64.wic" = "0011n8mjj1xrbkrdx0p5x07wh2q3n7wiacla797vy1mfhd6w4hzq";
  "isar-server-simple-server-2-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-simple-server-2-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-vlans-server-1
  # =========================================================================
  "isar-server-vlans-server-1-qemuamd64.wic" = "169q6xjvms8h39lpzylimgji9m08axnkb5mmz79cp15ww3c6p9wm";
  "isar-server-vlans-server-1-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-vlans-server-1-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-vlans-server-2
  # =========================================================================
  "isar-server-vlans-server-2-qemuamd64.wic" = "030g7r38d8zx6vj70qz11b2lrvyhvaaxr0vl05n9gsa7b05wqidr";
  "isar-server-vlans-server-2-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-vlans-server-2-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-bonding-vlans-server-1
  # =========================================================================
  "isar-server-bonding-vlans-server-1-qemuamd64.wic" = "0qygp4mvb9x6yl74rksi74wlpfyxadf7q0bccakjc3h32kwp57s9";
  "isar-server-bonding-vlans-server-1-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-bonding-vlans-server-1-qemuamd64-initrd.img" = "133wa0g4d03i1icxy29w4sqb7slg9j9svgp3c1h0c1bl8vn7c8m7";

  # =========================================================================
  # qemuamd64 - server-bonding-vlans-server-2
  # =========================================================================
  "isar-server-bonding-vlans-server-2-qemuamd64.wic" = "0i8x894bs8i9rlaqx6qsxpxgccc0c37k7qlf823j4l5dsgwlji97";
  "isar-server-bonding-vlans-server-2-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-bonding-vlans-server-2-qemuamd64-initrd.img" = "133wa0g4d03i1icxy29w4sqb7slg9j9svgp3c1h0c1bl8vn7c8m7";

  # =========================================================================
  # qemuamd64 - server-dhcp-simple-server-1
  # =========================================================================
  "isar-server-dhcp-simple-server-1-qemuamd64.wic" = "0c6diradlmn9shvy3cdk8wiq0129jz2316484rrmlbpfxkzqz634";
  "isar-server-dhcp-simple-server-1-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-dhcp-simple-server-1-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuamd64 - server-dhcp-simple-server-2
  # =========================================================================
  "isar-server-dhcp-simple-server-2-qemuamd64.wic" = "02wczm3k2v9hxanxaxdcgbxjmj8c04dc1g8xy3ljg0p781la8cyn";
  "isar-server-dhcp-simple-server-2-qemuamd64-vmlinuz" = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
  "isar-server-dhcp-simple-server-2-qemuamd64-initrd.img" = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";

  # =========================================================================
  # qemuarm64 - base (Orin emulation profile — WIC images)
  # =========================================================================
  "isar-base-qemuarm64.wic" = "07wf98kmj73lmxlzbn18rab7bzzfn984dcfrslksxhnrrhcm7dxa";
  "isar-base-qemuarm64-vmlinux" = "1bkb7ndk2ylhc4xwcwi9s6cj66z15yllccsy8kayg3xw6pgk1y0j";
  "isar-base-qemuarm64-initrd.img" = "0xab92fayps5ckhpadjrd81kr8j3fah1dl8svcjgvcrcr3a6szmn";

  # =========================================================================
  # qemuarm64 - server (Orin emulation profile — WIC images)
  # =========================================================================
  "isar-server-qemuarm64.wic" = "08p32lyk942gkwrwd7fzpcfq0sagdrglg81bfbx0c6sjlqzaa6pz";
  "isar-server-qemuarm64-vmlinux" = "1bkb7ndk2ylhc4xwcwi9s6cj66z15yllccsy8kayg3xw6pgk1y0j";
  "isar-server-qemuarm64-initrd.img" = "0xab92fayps5ckhpadjrd81kr8j3fah1dl8svcjgvcrcr3a6szmn";

  # =========================================================================
  # jetson-orin-nano - base
  # =========================================================================
  "isar-base-jetson-orin-nano.tar.gz" = "1dj5ydl85rq15rcqv7xpmvyhp9q36325aw2cacl6n94crkgwb29y";

  # =========================================================================
  # jetson-orin-nano - server
  # =========================================================================
  "isar-server-jetson-orin-nano.tar.gz" = "117bbk3vr7vxanbi2dzr4hdibvvx9pa7jd74m4iwjw8iwr50k973";

  # =========================================================================
  # amd-v3c18i - agent
  # =========================================================================
  "isar-agent-amd-v3c18i.wic" = "018j6fm0sczhcpd1r1cfakbyxwb57y09j8br0dsr8lag55dd3j5n";
}
