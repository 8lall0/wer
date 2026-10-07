// This file follows MAME's Game Boy cartridge emulation
// (src/devices/bus/gameboy: rom.cpp, mbc.cpp, mbc3.cpp, liebao.cpp,
// slmulti.cpp, gbck003.cpp; copyright Vas Crabb, Wilbert Pol) under its
// BSD 3-Clause license:
//
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are
//   met: (1) Redistributions of source code must retain the above copyright
//   notice, this list of conditions and the following disclaimer.
//   (2) Redistributions in binary form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//   (3) Neither the name of the copyright holder nor the names of its
//   contributors may be used to endorse or promote products derived from
//   this software without specific prior written permission.
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
//   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. (See
//   LICENSE-mame for the full text.)
//
// The table of known dumps comes from MAME's software lists (hash/gameboy.xml,
// hash/gbcolor.xml), which are CC0.
module cart;

// Unlicensed boards whose dumps nothing in the header gives away: they are
// known by the whole ROM's CRC (KNOWN_DUMPS), or Yong Yong's type $EA.
//   Rocket Games  $3F00 fine bank, $3FC0 coarse bank (16 per coarse);
//                 $0000-$3FFF shows the coarse bank's first. 8 KiB RAM, fixed.
//   La Sa Ma      $2080 fine bank (4 per coarse), $6000 bit 1 coarse.
//   Yong Yong     $2000: the bank at $4000.
//   Rockman 8     MBC1-like: $2000-$3FFF, 5 bits, banks above $0F lose 8.
//   SM3 Special   $2000-$2FFF through a table, $5000-$5FFF bit 5 a remap.
//   New GBC HK    $2000-$3FFF fine bank (bit 7: protection reads at
//                 $4000-$4FFF), $4000-$5FFF coarse.
//   VF001         MBC5; protection commands at $6000/$7000-$700A (readback
//                 values at an address, a split of $0000-$3FFF).
//   Liebao        $2000-$2FFF: 8 KiB pages 2n, 2n+1 at $4000 and $6000;
//                 $70D2 the $6000 page alone.
//   Chong Wu      MBC5; the first read of $41C3 gives $5D.
//   SL multicart  configuration commands ($5xxx command, $7xxx argument):
//                 the game's ROM base and size, RAM, then a reset.
//   GBCK003       configuration at $7B00-$7B02, then a reset.
// MAME's Rocket and Sachen logo spoofing (a bootleg logo on screen, Nintendo's
// to the boot ROM's check) isn't needed: wer's boot ROMs don't check it.

struct Unlicensed {
	ushort coarse;
	ushort fine;
	bool   sm3sp_remap;
	bool   ngbc_prot;       // New GBC HK: protection reads at $4000-$4FFF
	bool   chong_checked;
	// Liebao
	ushort lb_low;
	ushort lb_high;
	bool   lb_high_set;
	// SL multicart
	ushort sl_cmd;
	ushort sl_base;
	ushort sl_high;
	ushort sl_mask;
	ushort sl_zero;
	bool   sl_ram_ok;
	char   sl_ram_base;
	char   sl_ram_page;
	char   sl_ram_mask;
	char   sl_mode;         // 0: configuration, 1: MBC5 game, 2: MBC1 game
	// GBCK003
	char   ck_outer;
	char   ck_inner;
	char   ck_mux;
	bool   ck_config;
	// VF001
	bool   vf_enable;
	char   vf_data;
	char   vf_preload;
	ushort vf_rb_addr;
	char   vf_rb_bank;
	char   vf_rb_len;
	char[4] vf_rb_data;
	char   vf_rb_count;
	ushort vf_split_addr;
	bool   vf_split;
	char   vf_upper;
}

fn bool Mbc.unlicensed(self) {
	switch (self) {
		case ROCKET: case LASAMA: case YONG: case ROCKMAN8: case SM3SP: case NEWGBCHK:
		case VF001: case LIEBAO: case CHONGWU: case SLMULTI: case GBCK003:
			return true;
		default:
			return false;
	}
}

// --- detection ---------------------------------------------------------------

struct KnownDump {
	uint crc;
	Mbc  mbc;
}

// By CRC, sorted.
const KnownDump[*] KNOWN_DUMPS = {
	{ 0x01F1FCEE, BBD },       // Digimon Adventure 2001
	{ 0x0634C196, ROCKET },    // Full Time Soccer & Hang Time Basketball (Europe)
	{ 0x0881ED84, LI_CHENG },  // Xin Guangming Yu Hei'an 2 - Zhushen De Yichan (China)
	{ 0x09DEE8CB, LI_CHENG },  // Gang Dan Wuyu II (China)
	{ 0x0A504426, SACHEN },    // 4 in 1 + 8 in 1 (World, 4B-007)
	{ 0x0AD5B775, ROCKET },    // Pocket Smash Out & Race Time (Europe)
	{ 0x0B20D3AF, SINTAX },    // Chuan Shuo (China)
	{ 0x0BC7A3C6, SACHEN },    // Beast Fighter (Taiwan)
	{ 0x0C38A775, M161 },      // Mani 4 in 1 (China, DMG-601 CHN)
	{ 0x0DB9FDFA, SINTAX },    // Pian Wai Zhang Huangjin no Taiyou - Fengyin De Yuangu Lianji
	{ 0x0DD2B42B, NT_NEW },    // Y?ngxi?ng Chu?nshu? (China)
	{ 0x0EB8DDFB, SACHEN },    // 31 in 1 Mighty Mix (Taiwan)
	{ 0x114E1F1E, SACHEN },    // 4 in 1 (Europe, 4B-009)
	{ 0x1219EEC6, SINTAX },    // 2003 Shuma Bao Long - Gedou Ban (China)
	{ 0x14355371, NEWGBCHK },  // K?ud?i Gu?ish?u - D?ngzu? Pi?n (China)
	{ 0x1517D27E, MBC5 },      // Chao Jinhua - Shuma Baobei D-3 (China, ripped from 10 in 1 multicart)
	{ 0x154F885B, LI_CHENG },  // Luoke Ren DX6 (China)
	{ 0x1823E24D, SINTAX },    // Sh?ngu? D?gu? zh? ?m? Ch?ng (China)
	{ 0x1A369DD5, SINTAX },    // Donkey Kong 5 - The Journey of Over Time and Space (China)
	{ 0x1A6FE765, NT_NEW },    // Street Fighter Zero 4 (China)
	{ 0x1A719EAD, SACHEN },    // Thunder Blast Man (Europe)
	{ 0x1B1C6F68, VF001 },     // G?d?u Ji?n Sh?n - Soul Falchion (Taiwan)
	{ 0x1B3E1243, SINTAX },    // Xiao Shi Mi Shi (China)
	{ 0x1B5BEF4B, NT_NEW },    // Pok?mon Diamond: Special Pikachu Edition (China)
	{ 0x1CB8E67F, BBD },       // Garou: Mark of the Wolves 2001
	{ 0x1FEAEB47, SINTAX },    // Chao Ji Ji Qi Ren Da Zhan X (China, alt)
	{ 0x20E40D8F, LI_CHENG },  // Xin Shediao Yingxiong Chuan (China)
	{ 0x21524051, SACHEN },    // 31-in-1 Mighty Mix (Australia)
	{ 0x23679231, WISDOM },    // The Holy Bible - King James Version (USA)
	{ 0x23C19A4D, LI_CHENG },  // Shuma Baobei - DX6 (China)
	{ 0x23F291B3, LI_CHENG },  // Taikong Baobei (China, Li Cheng)
	{ 0x25A857AF, SINTAX },    // Shaolin Shisan Gun - Yingxiong Jiu Zhu (China)
	{ 0x2705CA20, PKJD },      // Pok?mon Vision Jade
	{ 0x279BE0CC, SINTAX },    // Chao Ji Ji Qi Ren Da Zhan X (China)
	{ 0x28519AB1, SLMULTI },   // Sh?sh?ng Ch?oqi?ng RPG + G?d?u + Y?zh? B?n Z?h? K? 18 in 1
	{ 0x2B2D9868, ROCKET },    // Space Invasion (Europe)
	{ 0x2C0D43A9, SINTAX },    // Spider-Man 3 (China)
	{ 0x2C922ED6, SINTAX },    // Quan Ba Tian Xia (China)
	{ 0x2E5497EF, WISDOM },    // Exodus (USA)
	{ 0x2EE18AB2, NT_NEW },    // Sh?m? B?o L?ng 02 4 (China)
	{ 0x31F14D99, LI_CHENG },  // Mingzhu Koudai Guaishou II (China)
	{ 0x3207B7D9, ROCKET },    // Hang Time Basketball (Europe)
	{ 0x322C3816, SINTAX },    // Xiao Taichi - Shenhua Lixian (China)
	{ 0x34C1A63A, SINTAX },    // Fantastic Simulated Battle (China)
	{ 0x363808B4, LI_CHENG },  // Shuma Bao Long - Diannao Pian (China)
	{ 0x366067E8, SINTAX },    // M?nghu?n M?n? Zh?n ? (China)
	{ 0x3A0E9B6F, SINTAX },    // Pocket Monster Ruby (China)
	{ 0x3F0D046B, BBD },       // Digimon Adventure 6 2002
	{ 0x416E6EFA, GGB81 },     // M?ch?ng W?y? 6 GB (China)
	{ 0x42A2FDF8, SACHEN },    // 4 in 1 + 8 in 1 (World, 4B-001)
	{ 0x4A083B6E, LI_CHENG },  // Shuihu Zhuan - Jingdian Ban (China)
	{ 0x4C76D4D8, SINTAX },    // K?ud?i Gu?ish?u - L?nb?osh? (China)
	{ 0x4E600093, SINTAX },    // W?ix?ng T?nxi?n zh? X?ngqi? D?zh?n (China)
	{ 0x509F1BB5, SINTAX },    // The Firmament Baby (China)
	{ 0x50BABE99, LI_CHENG },  // Chao Jinhua - Shuma Bao Long - Zuanshi Ban (China)
	{ 0x51F92403, SINTAX },    // Luoke Ren X5 (China)
	{ 0x55494332, SINTAX },    // Matel Gear II (China)
	{ 0x599C867D, ROCKET },    // Race Time (Europe)
	{ 0x5C388C6D, LI_CHENG },  // Emo Cheng DX (China)
	{ 0x5E4266A7, SM3SP },     // Super Mario 3 Special (China)
	{ 0x5E438DB8, SACHEN },    // 4 in 1 (Europe, 4B-002)
	{ 0x5F2D6317, LI_CHENG },  // Yingxiong Tianxia (China)
	{ 0x5FED0068, YONG },      // Sonic 3D Blast 5 (China)
	{ 0x602951A6, SINTAX },    // Yuenan Zhanyi X - Shenru Dihou (China)
	{ 0x618080CD, LI_CHENG },  // Shuihu Shenshou (China, Li Cheng)
	{ 0x620E785D, CHONGWU },   // Ch?ngw? Xi?o J?ngl?ng - Ji? J?n T? Zh? W?ng (China)
	{ 0x62D9350E, SACHEN },    // 4 in 1 (Europe, 4B-007)
	{ 0x6791B106, NT_NEW },    // Digimon Pocket (China)
	{ 0x685E76DF, SINTAX },    // Digimon Crystal II (China)
	{ 0x6908F4AF, ROCKET },    // ATV Racing & Karate Joe (Europe, alt)
	{ 0x6A184C55, ROCKET },    // Space Invasion & Karate Joe (Europe)
	{ 0x6A99A079, SACHEN },    // Super 16 in 1 (Taiwan)
	{ 0x6DF86DB6, SINTAX },    // Xing Qiu Da Zhan II - Ke Long Ren Zhan Yi (China)
	{ 0x6E447A33, NT_NEW },    // Pok?mon: Mewtwo Strikes Back (China)
	{ 0x71536B8E, SINTAX },    // Pocket Monster Saphire (China)
	{ 0x71B8EA17, LIEBAO },    // Dragon Ball Z English
	{ 0x740E9BC8, SACHEN },    // 4 in 1 (Europe, 4B-008)
	{ 0x74D71B0C, SINTAX },    // 2003 Gu Huo Lang II - The Huge Adventure (China)
	{ 0x772337F4, BBD },       // Harry Potter (China, English)
	{ 0x786EB7A4, LI_CHENG },  // Yingxiong Jian 2 (China)
	{ 0x7987D5CD, ROCKET },    // ATV Racing (Europe)
	{ 0x7AA7EEA5, GGB81 },     // M? Ji? Chu?nshu? (China)
	{ 0x7CFF9F0B, SINTAX },    // 2003 Digitmon Sapphire (China)
	{ 0x7E1351CF, SACHEN },    // Rocman-X (Taiwan)
	{ 0x8059E009, SINTAX },    // F?ngku?ng ?g?i ? - Ch?oj? Zh?d?nr?n (Taiwan)
	{ 0x80C4FD52, SINTAX },    // Moshou Shiji - Zhanshen (China)
	{ 0x8160B3F5, SINTAX },    // Zhi Huan Wang - Shou Bu Qu (China)
	{ 0x82F06E93, SACHEN },    // 4 in 1 (Europe, 4B-001)
	{ 0x842CB4FE, SINTAX },    // Feng Zhi Gou II (China)
	{ 0x859457C8, SINTAX },    // Ha Li Xiao Zi Di Er Bu - Mi Shi De Mi (China)
	{ 0x8A64C933, SINTAX },    // Bynasty Warriors Advance 5 (China)
	{ 0x8B8B84EC, SINTAX },    // Yongzhe Dou E Long VIII (China)
	{ 0x8B9F30D7, LI_CHENG },  // Taikong Zhanshi - Jingdian Ban (China)
	{ 0x9268BB9F, SINTAX },    // Yuenan Zhanyi 3 (China)
	{ 0x9507E5D3, GGB81 },     // Sh?m? B?o L?ng: K?ud?i B?n (China)
	{ 0x95398DA5, SACHEN },    // 4 in 1 (Europe, 4B-006)
	{ 0x955BC6AD, SINTAX },    // Guiwu Zhe 2 (China)
	{ 0x95C322C9, SINTAX },    // Zhen San Guo Wu Shuang 2 - Shin Sangokumusou 2 (China)
	{ 0x96662E76, SINTAX },    // Digimon Yellow Jade (China)
	{ 0x97280455, NT_NEW },    // Capcom Vs. SNK: Millennium Fight 2001 (China)
	{ 0x973D38A8, SINTAX },    // 2003 Crash Bandicoot II Advance - The Huge Adventure (China)
	{ 0x989A5FE0, LASAMA },    // L?s?m? Chu?nq? - Story of Lasama (Taiwan)
	{ 0x998AD382, SINTAX },    // Koudai Yaoguai - Baijin Ban (China)
	{ 0xA07B6E79, ROCKET },    // ATV Racing & Karate Joe (Europe)
	{ 0xA2C4F7B3, LI_CHENG },  // Teshu Budui 2 - Jidi (China)
	{ 0xA321FF7D, SINTAX },    // Fantasic ShaoLin Kungfu (China)
	{ 0xA43AB22B, NT_NEW },    // Digimon 2 (China)
	{ 0xA477C7CE, LI_CHENG },  // Mingzhu Koudai Guaishou III ~ Digimon Fight ~ El Monstruo (C
	{ 0xA5F686C3, LI_CHENG },  // Shi Mian Maifu - Fengyun Pian (China)
	{ 0xA90061E9, NT_NEW },    // Digimon 02 4 (China)
	{ 0xA962AD73, SINTAX },    // Hai Zhan Qi Bing (China)
	{ 0xA98EEC81, LI_CHENG },  // Emo Cheng 2 - Fengyun Pian (China)
	{ 0xA9DD9DA7, SINTAX },    // Ch?oj? Y?ns? Xi?ozi ? - Super Sonik (China)
	{ 0xAA07F269, PKJD },      // Pok?mon Jade Version
	{ 0xAABBEC08, NT_NEW },    // Sh?m? B?o L?ng 3 Shu?j?ng B?n (China)
	{ 0xAECA45BE, SINTAX },    // Laofuzi Chuanqi (China)
	{ 0xAFD7A0CC, VF001 },     // Ch?oj? G?d?u 2001 Alpha (Taiwan)
	{ 0xB0237467, NEWGBCHK },  // Gu?ish?u Go! Go! ? (China)
	{ 0xB087710C, SLMULTI },   // New Super Color 145 in 1 (China)
	{ 0xB0D45B6A, LI_CHENG },  // Shuma Baobei - Huojian Bingtuan (China)
	{ 0xB18465D2, SACHEN },    // 4 in 1 + 8 in 1 + 16 in 1 (World, 4B-005)
	{ 0xB580CB1F, SACHEN },    // Street Hero (Taiwan)
	{ 0xB67999AE, SINTAX },    // Shuma Bao Long - Shuijing Ban II (China)
	{ 0xB8A54E29, ROCKET },    // Karate Joe (Europe)
	{ 0xB99BEDA2, ROCKET },    // Full Time Soccer (Europe)
	{ 0xBA03BD71, LI_CHENG },  // Shuma Bao Long 3 - Shuijing Ban (China, Li Cheng)
	{ 0xBD4C1065, ROCKET },    // Space Invasion & Painter (Europe)
	{ 0xC294AA21, SACHEN },    // 4 in 1 (Taiwan, 4B-003)
	{ 0xC3CEDAED, LI_CHENG },  // Sh?m? B?ob?i: H?i Zh? Sh?n (China)
	{ 0xC4EBA914, SINTAX },    // Bingyuan Lixian Ji II (China)
	{ 0xC69A19F6, SACHEN },    // 4 in 1 (Europe, 4B-004)
	{ 0xCBD14276, ROCKET },    // Pocket Smash Out (Europe)
	{ 0xCC131A94, ROCKMAN8 },  // Rockman 8 (China)
	{ 0xCCFDD63A, SINTAX },    // Qilongzhu Z 3 ~ Dragon Ball - Advance Adventure (China)
	{ 0xD0FECE32, NT_NEW },    // Harry Potter 3 (China)
	{ 0xD311EFCC, SINTAX },    // Zhi Zhu Xia III (China)
	{ 0xD91E3F98, LI_CHENG },  // Mo Jie 3 - Bu Wanme De Shijie (China)
	{ 0xDB3C8B95, SINTAX },    // Harry Xiao Zi IV (China)
	{ 0xDBE0F44E, SINTAX },    // Dragon Ball Z III 2002 Fighting
	{ 0xDC3171AD, SLMULTI },   // Y?n B?n Zh?ngw?n RPG Zh?nl?? + D?ngzu? + Y?zh? 12 in 1
	{ 0xDDF36A27, LI_CHENG },  // Taikong Zhanshi DX3 - Zuizhong Huanxiang (China)
	{ 0xDE136996, LI_CHENG },  // Sanguozhi Wudai (China)
	{ 0xDEE597FC, SINTAX },    // W?ngz? Ti?nt?ng (Taiwan)
	{ 0xE0CF879B, WISDOM },    // Joshua (USA)
	{ 0xE1668B49, VF001 },     // N?w?ng G?d?u 2000 (Taiwan)
	{ 0xE1D61242, SINTAX },    // Ch?or?n T?g?ngdu? (Taiwan)
	{ 0xE4068D7D, GBCK003 },   // Color GameBoy 188 in 1 (Hong Kong)
	{ 0xE7224F14, SACHEN },    // 4 in 1 + 8 in 1 (World, 4B-002)
	{ 0xE7A26B31, WISDOM },    // The NIV Holy Bible (USA)
	{ 0xE7D9D377, YONG },      // Sh?q? Sh?d?i - J?ngl?ng Wang D?nsh?ng (China)
	{ 0xE81701E8, SINTAX },    // Xi?nd?n Ch?or?n - Ultraman (Taiwan)
	{ 0xE9488E13, NT_NEW },    // Pok?mon Jade: Special Pikachu Edition (China)
	{ 0xEF4BBB34, SINTAX },    // H?j?n Zhu?ngb?i ? (China)
	{ 0xF19E780C, SINTAX },    // Jing Ling Wang III (China)
	{ 0xF2D0F0AE, SINTAX },    // Taikong Baobei (China, Sintax)
	{ 0xF2FC4884, LI_CHENG },  // Xiyou Ji (China)
	{ 0xF4310EB3, SACHEN },    // 4 in 1 (Europe, 4B-005)
	{ 0xF4801F21, ROCKET },    // Painter (Europe)
	{ 0xF4D63A7E, SINTAX },    // Ju?du? W?l? (China)
	{ 0xF68D980A, SLMULTI },   // 36 in 1 (SL36-0032)
	{ 0xF7A961BA, WISDOM },    // Spiritual Warfare (USA)
	{ 0xFB60D1C5, SACHEN },    // Super 6 in 1 (Taiwan)
	{ 0xFC844E0E, LI_CHENG },  // Shuma Baobei - Chao Meng Meng Fanji Zhan (China)

};

fn Mbc? known_mbc(char[] rom) {
	if (rom.len > 0x147 && rom[0x147] == 0xEA) return YONG;
	if (rom.len < 0x8000 || rom.len > 0x800000) return NOT_A_BOOTLEG~;
	uint crc = crc32(rom);
	usz lo = 0;
	usz hi = KNOWN_DUMPS.len;
	while (lo < hi) {
		usz mid = (lo + hi) / 2;
		if (KNOWN_DUMPS[mid].crc < crc) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	if (lo < KNOWN_DUMPS.len && KNOWN_DUMPS[lo].crc == crc) return KNOWN_DUMPS[lo].mbc;
	return NOT_A_BOOTLEG~;
}

// --- power-on and reset --------------------------------------------------------

fn void Cartridge.unl_init(&self) {
	Unlicensed* u = &self.unl;
	switch (self.mbc) {
		case ROCKET:
		case LASAMA:
			u.fine = 1;
			self.ram_enabled = true;
		case YONG:
		case ROCKMAN8:
		case SM3SP:
			self.rom_bank = 1;
			self.ram_enabled = true;
		case LIEBAO:
			u.lb_low = 2;
			u.lb_high = 3;
		case SLMULTI:
			u.sl_cmd = 0x100;
			u.sl_mask = 1;
			u.sl_high = 1;
		case GBCK003:
			u.ck_mux = 0xFF;
			u.ck_config = true;
			u.ck_inner = 1;
			self.ram_enabled = true;
		case NEWGBCHK:
			self.rom_bank = 0;
		default:
			break;
	}
}

// The console reset from the cartridge (Cartridge.reset_request): what the
// boards set again then; their configuration stays.
fn void Cartridge.unl_reset(&self) {
	self.reset_request = false;
	self.rom_mapped = false;
	switch (self.mbc) {
		case SLMULTI:
			self.unl.sl_high = 1;
			self.ram_enabled = false;
			self.sl_update_ram();
		case GBCK003:
			self.unl.ck_inner = 1;
		case HICOL:
			self.rom_bank = 1;
			self.ram_enabled = false;
		default:
			break;
	}
}

// --- ROM ---------------------------------------------------------------------

fn bool Cartridge.unl_reads(&self) {
	switch (self.mbc) {
		case NEWGBCHK: case VF001: case LIEBAO: case CHONGWU: return true;
		default: return false;
	}
}

fn usz bank16(Cartridge* c, uint bank, ushort addr) => (usz)wrap_bank(bank, c.rom.len, 0x4000) * 0x4000 + (usz)(addr & 0x3FFF);

fn usz Cartridge.unl_rom_offset(&self, ushort addr) {
	Unlicensed* u = &self.unl;
	bool high = addr >= 0x4000;
	switch (self.mbc) {
		case ROCKET:
		case LASAMA:
			uint bits = self.mbc == ROCKET ? 4 : 2;
			return bank16(self, high ? (uint)u.fine | (uint)u.coarse << bits : (uint)u.coarse << bits, addr);
		case NEWGBCHK:
			return bank16(self, high ? (uint)u.fine | (uint)u.coarse << 7 : (uint)u.coarse << 7, addr);
		case YONG:
		case ROCKMAN8:
		case SM3SP:
			return bank16(self, high ? self.rom_bank : 0, addr);
		case VF001:
		case CHONGWU:
			return bank16(self, high ? self.rom_bank : 0, addr);
		case LIEBAO:
			if (!high) return addr;
			uint page = addr < 0x6000 ? u.lb_low : u.lb_high;
			return (usz)wrap_bank(page, self.rom.len, 0x2000) * 0x2000 + (usz)(addr & 0x1FFF);
		case SLMULTI:
			ushort base = u.sl_base & ~u.sl_mask;
			if (!high) return bank16(self, base, addr);
			ushort hi = u.sl_high & u.sl_mask;
			return bank16(self, base | (hi ? hi : u.sl_zero & u.sl_mask), addr);
		case GBCK003:
			if (!high) return bank16(self, (uint)u.ck_outer << 1, addr);
			return bank16(self, ((uint)(u.ck_outer & u.ck_mux) << 1) | (u.ck_inner & ~((uint)u.ck_mux << 1)), addr);
		default:
			return addr;
	}
}

// A ROM read with the boards' protection.
fn char Cartridge.unl_read(&self, ushort addr) {
	Unlicensed* u = &self.unl;
	usz off = self.unl_rom_offset(addr);
	char v = off < self.rom.len ? self.rom[off] : 0xFF;
	switch (self.mbc) {
		case NEWGBCHK:
			if (!u.ngbc_prot || addr < 0x4000) return v;
			if (addr >= 0x5000) return 0xFF;
			return ngbc_protection((char)(addr >> 4));
		case CHONGWU:
			if (addr == 0x41C3 && !u.chong_checked) {
				u.chong_checked = true;
				return 0x5D;
			}
			return v;
		case VF001:
			return self.vf001_read(addr, v);
		default:
			return v;
	}
}

// Bits 6, 4, 2 and 0 of `x`, as a nibble.
fn char even_bits(uint x) => (char)((x >> 6 & 1) << 3 | (x >> 4 & 1) << 2 | (x >> 2 & 1) << 1 | (x & 1));

fn char ngbc_protection(char o) {
	uint x = o;
	switch (o & 7) {
		case 0: return o;
		case 1: return o ^ 0xAA;
		case 2: return o ^ 0x55;
		case 3: return (char)(o >> 1 | o << 7);
		case 4: return (char)(o << 1 | o >> 7);
		case 5:
			char r;
			for (int i = 0; i < 8; i++) r |= (char)((o >> i & 1) << (7 - i));
			return r;
		case 6: return even_bits(x | x >> 1) << 4 | even_bits(x & x >> 1);
		default: return even_bits(x ^ (~x >> 1)) << 4 | even_bits(x ^ (x >> 1));
	}
}

fn char Cartridge.vf001_read(&self, ushort addr, char v) {
	Unlicensed* u = &self.unl;
	if (!u.vf_rb_count && u.vf_rb_len) {
		char bank = addr >= 0x4000 ? (char)self.rom_bank : 0;
		if (addr == u.vf_rb_addr && bank == u.vf_rb_bank) u.vf_rb_count = u.vf_rb_len;
	}
	if (u.vf_rb_count) {
		char i = (u.vf_rb_len - u.vf_rb_count) & 3;
		u.vf_rb_count--;
		return u.vf_rb_data[i];
	}
	if (u.vf_split && addr >= u.vf_split_addr && addr < 0x4000) {
		usz off = bank16(self, u.vf_upper, addr);
		return off < self.rom.len ? self.rom[off] : 0xFF;
	}
	return v;
}

// --- writes ------------------------------------------------------------------

const char[32] SM3SP_BANKS = {
	0x00, 0x04, 0x01, 0x05, 0x02, 0x06, 0x03, 0x05, 0x08, 0x0C, 0x03, 0x0D, 0x03, 0x0B, 0x0B, 0x08,
	0x05, 0x06, 0x0B, 0x0D, 0x08, 0x06, 0x13, 0x0B, 0x08, 0x05, 0x05, 0x08, 0x0B, 0x0D, 0x06, 0x05,
};

fn void Cartridge.unl_control(&self, ushort addr, char value) {
	Unlicensed* u = &self.unl;
	switch (self.mbc) {
		case ROCKET:
			if (addr == 0x3F00) u.fine = value ? value : 1;
			if (addr == 0x3FC0) u.coarse = value;
		case LASAMA:
			if (addr == 0x2080) u.fine = value & 3;
			if (addr == 0x6000 && !(value & 0x80)) u.coarse = (value >> 1) & 1;
		case YONG:
			if (addr == 0x2000) self.rom_bank = value;
		case ROCKMAN8:
			if (addr >= 0x2000 && addr < 0x4000) {
				char d = value & 0x1F;
				self.rom_bank = !d ? 1 : d > 0x0F ? d - 8 : d;
			}
		case SM3SP:
			if (addr >= 0x2000 && addr < 0x3000) {
				char b = SM3SP_BANKS[value & 0x1F];
				if (u.sm3sp_remap) {
					switch (b) {
						case 0x02: b = 0x04;
						case 0x03: b = 0x06;
						case 0x04: b = 0x02;
						case 0x05: b = 0x03;
						case 0x06: b = 0x05;
						case 0x0B: b = 0x0D;
						case 0x0C: b = 0x0B;
						case 0x0D: b = 0x0C;
						default: break;
					}
				}
				self.rom_bank = b;
			} else if (addr >= 0x5000 && addr < 0x6000) {
				u.sm3sp_remap = (value & 0x20) != 0;
			}
		case NEWGBCHK:
			switch {
				case addr < 0x2000: self.ram_enabled = value == 0x0A;
				case addr < 0x4000:
					u.fine = value & 0x7F;
					u.ngbc_prot = (value & 0x80) != 0;
				case addr < 0x6000: u.coarse = value;
				default: break;
			}
		case VF001:
			if (addr >= 0x6000 && addr <= 0x700F && (addr & 0x0FF0) == 0) self.vf001_command((ushort)(addr & 0x100F), value);
			self.mbc5_control(addr, value);
		case CHONGWU:
			self.mbc5_control(addr, value);
		case LIEBAO:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x3000:
					u.lb_low = (ushort)value << 1;
					if (u.lb_high_set || (addr & 0xFF) == 0xD2) {
						u.lb_high_set = false;
					} else {
						u.lb_high = (ushort)value << 1 | 1;
					}
				case addr >= 0x4000 && addr < 0x6000: self.ram_bank = value & 0x0F;
				case addr >= 0x7000:
					if ((addr & 0xFF) == 0xD2) {
						u.lb_high_set = true;
						u.lb_high = (ushort)value << 1 | 1;
					}
				default: break;
			}
		case SLMULTI:
			self.sl_control(addr, value);
		case GBCK003:
			switch {
				case addr >= 0x2000 && addr < 0x4000:
					char d = value & 0x1F;
					u.ck_inner = d ? d : 1;
				case addr == 0x7B00: if (u.ck_config) u.ck_outer = value;
				case addr == 0x7B01: if (u.ck_config) u.ck_mux = value;
				case addr == 0x7B02:
					if (u.ck_config && value == 0xF0) {
						u.ck_config = false;
						self.reset_request = true;
					}
				default: break;
			}
		default:
			break;
	}
}

fn void Cartridge.vf001_command(&self, ushort offset, char value) {
	Unlicensed* u = &self.unl;
	if (offset == 0x1000 && value == 0x96) {
		u.vf_enable = true;
		u.vf_data = u.vf_preload;
		return;
	}
	if (offset == 0x100F && value == 0x96) {
		u.vf_enable = false;
		return;
	}
	if (!u.vf_enable) return;
	if ((offset >= 0x0001 && offset < 0x1000) || offset >= 0x100B) return;
	// The previous value turned right, with the new one XORed in.
	u.vf_data = (char)(u.vf_data >> 1 | u.vf_data << 7) ^ value;
	char d = u.vf_data;
	switch (offset) {
		case 0x0000: u.vf_upper = d;
		case 0x1000: if (d & 4) u.vf_rb_len = (d & 3) + 1;
		case 0x1001: u.vf_rb_addr = (u.vf_rb_addr & 0xFF00) | d;
		case 0x1002: u.vf_rb_addr = (u.vf_rb_addr & 0x00FF) | (ushort)d << 8;
		case 0x1003: u.vf_rb_bank = d;
		case 0x1004: case 0x1005: case 0x1006: case 0x1007: u.vf_rb_data[offset & 3] = d;
		case 0x1008: u.vf_split = (d & 0x0F) == 0x0F;
		case 0x1009: u.vf_split_addr = (u.vf_split_addr & 0xFF00) | d;
		case 0x100A: u.vf_split_addr = (u.vf_split_addr & 0x00FF) | (ushort)d << 8;
		default: break;
	}
}

fn void Cartridge.sl_update_ram(&self) {
	Unlicensed* u = &self.unl;
	self.ram_bank = (u.sl_ram_base & ~u.sl_ram_mask) | (u.sl_ram_page & u.sl_ram_mask);
}

fn void Cartridge.sl_control(&self, ushort addr, char value) {
	Unlicensed* u = &self.unl;
	// Configuration mode, and MBC5 mode, lay their registers over these.
	if (u.sl_mode == 0 && addr >= 0x5000 && addr < 0x6000) {
		u.sl_cmd = value;
		return;
	}
	if (u.sl_mode == 0 && addr >= 0x7000 && addr < 0x8000) {
		self.sl_command(value);
		return;
	}
	if (u.sl_mode == 1 && addr >= 0x3000 && addr < 0x4000) return; // MBC5's ninth bank bit: not wired
	switch {
		case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A && u.sl_ram_ok;
		case addr < 0x4000: u.sl_high = value;
		case addr < 0x6000:
			u.sl_ram_page = value & 0x0F;
			self.sl_update_ram();
		default: break;
	}
}

fn void Cartridge.sl_command(&self, char data) {
	Unlicensed* u = &self.unl;
	switch (u.sl_cmd) {
		case 0x55:
			u.sl_base = (u.sl_base & 0xFDFF) | (ushort)((data >> 3) & 1) << 9;
			u.sl_mask = (ushort)((2u << (~data & 7)) - 1);
			switch ((data >> 5) & 3) {
				case 0:
					u.sl_zero = 0;
					u.sl_mode = 1; // MBC5 games
				case 3:
					u.sl_zero = 1;
					u.sl_mode = 2; // MBC1 games
				default:
					u.sl_mode = 2;
			}
			if (data & 0x80) self.reset_request = true;
		case 0xAA:
			u.sl_base = (u.sl_base & 0xFE01) | (ushort)data << 1;
		case 0xBB:
			u.sl_ram_ok = (data & 0x20) != 0;
			u.sl_ram_base = data & 0x0F;
			u.sl_ram_mask = (data & 0x10) ? 0x00 : 0x03;
			self.sl_update_ram();
			if (!u.sl_ram_ok) self.ram_enabled = false;
		default:
			break;
	}
	u.sl_cmd = 0x100;
}
