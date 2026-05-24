#include "FileSystem.h"
#include "FileStream.h"
#include "FileSystemType.h"
#include <string>

#ifdef HAS_RNS

#include <Log.h>

// ESP32 LittleFS CONFIG_LITTLEFS_OBJ_NAME_LEN=64, but the actual usable
// limit is 62 chars due to off-by-one in the length check.
// microReticulum uses 64-char SHA256 hex hashes as cache filenames.
// Truncate to 32 chars (128 bits) — still astronomically collision-proof.
#define FS_NAME_MAX 64  // SHA256 hex hash length used for cache filenames
static std::string truncate_filename(const char* file_path) {
	std::string path(file_path);
	size_t last_slash = path.rfind('/');
	if (last_slash == std::string::npos) {
		// No directory component — truncate entire path
		if (path.length() > FS_NAME_MAX) {
			path.resize(FS_NAME_MAX);
		}
	} else {
		std::string dir = path.substr(0, last_slash + 1);
		std::string name = path.substr(last_slash + 1);
		if (name.length() > FS_NAME_MAX) {
			name.resize(FS_NAME_MAX);
		}
		path = dir + name;
	}
	return path;
}

#if FS_TYPE == FS_TYPE_INTERNALFS

inline int _countLfsBlock(void *p, lfs_block_t block) {
	lfs_size_t *size = (lfs_size_t*) p;
	*size += 1;
	return 0;
}

lfs_ssize_t usedBlocks() {
    lfs_size_t size = 0;
    lfs_traverse(FS._getFS(), _countLfsBlock, &size);
    return size;
}

size_t usedBytes() {
	const lfs_config* config = FS._getFS()->cfg;
	const size_t usedBlockCount = usedBlocks();
	return config->block_size * usedBlockCount;
}

size_t totalBytes() {
	const lfs_config* config = FS._getFS()->cfg;
	return config->block_size * config->block_count;
}

#elif FS_TYPE == FS_TYPE_FLASHFS

Adafruit_FlashTransport_SPI g_flashTransport(SS, SPI);

//Flash definition structure for GD25Q16C Flash (RAK15001)
Cached_SPIFlash g_flash(&g_flashTransport);
SPIFlash_Device_t g_RAK15001 {
	.total_size = (1UL << 21),
	.start_up_time_us = 5000,
	.manufacturer_id = 0xc8,
	.memory_type = 0x40,
	.capacity = 0x15,
	.max_clock_speed_mhz = 15,
	.quad_enable_bit_mask = 0x00,
	.has_sector_protection = false,
	.supports_fast_read = true,
	.supports_qspi = false,
	.supports_qspi_writes = false,
	.write_status_register_split = false,
	.single_status_byte = true,
};

#endif


bool FileSystem::init() {
	TRACE("Initializing filesystem...");
	try {
#if FS_TYPE == FS_TYPE_SPIFFS
		// Initialize SPIFFS
		INFO("SPIFFS mounting filesystem");
		if (!SPIFFS.begin(true, "/spiffs")) {
			ERROR("SPIFFS filesystem mount failed");
			return false;
		}
		INFO("SPIFFS filesystem is ready");
#elif FS_TYPE == FS_TYPE_LITTLEFS
		// Initialize LittleFS
		INFO("LittleFS mounting filesystem");
		if (!LittleFS.begin(true, "/littlefs")) {
			ERROR("LittleFS filesystem mount failed");
			return false;
		}
		DEBUG("LittleFS filesystem is ready");
		// Check if the superblock has a restrictive name_max (e.g. 32 from
		// mklittlefs). The LittleFS superblock stores name_max at format time,
		// and the runtime downgrades to match it even if LFS_NAME_MAX=255.
		// Test with a 64-char filename; if it fails, reformat to get name_max=255.
		{
			const char* test_path = "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
			File tf = LittleFS.open(test_path, FILE_WRITE, true);
			if (tf) {
				tf.close();
				LittleFS.remove(test_path);
			} else {
				HEAD("LittleFS superblock has restrictive name_max, reformatting...", RNS::LOG_WARNING);
				// Save identity files before reformat
				RNS::Bytes transport_id, lxmf_id;
				read_file("/transport_identity", transport_id);
				read_file("/lxmf_identity", lxmf_id);
				LittleFS.end();
				LittleFS.format();
				if (!LittleFS.begin(false, "/littlefs")) {
					ERROR("LittleFS re-mount failed after reformat");
					return false;
				}
				// Restore identity files
				if (transport_id.size() > 0) {
					write_file_direct("/transport_identity", transport_id);
					INFO("Restored transport identity after reformat");
				}
				if (lxmf_id.size() > 0) {
					write_file_direct("/lxmf_identity", lxmf_id);
					INFO("Restored LXMF identity after reformat");
				}
				INFO("LittleFS reformatted with name_max=255");
			}
		}
#elif FS_TYPE == FS_TYPE_INTERNALFS
		// Initialize InternalFileSystem
		INFO("InternalFS mounting filesystem");
		if (!InternalFS.begin()) {
			// Auto-format inside InternalFS.begin() didn't recover. Force a
			// full format and retry once before giving up — same recovery as
			// eeprom_begin() so a brownout-corrupted FS unblocks itself.
			Serial.println("[FS] InternalFS mount failed, forcing format..."); Serial.flush();
			InternalFS.format();
			if (!InternalFS.begin()) {
				Serial.println("[FS] InternalFS unrecoverable after format"); Serial.flush();
				ERROR("InternalFS filesystem mount failed");
				return false;
			}
			Serial.println("[FS] InternalFS recovered after format"); Serial.flush();
		}
		INFO("InternalFS filesystem is ready");
		// Wiper-build option: when -DFORMAT_FS_ON_BOOT is set in build_flags,
		// selectively wipe RNS routing/cache state on every boot while
		// PRESERVING EEPROM provisioning files and identity files. A full
		// format would destroy EEPROM provisioning (which lives on InternalFS
		// because HAS_EEPROM=false on this board), leaving RNS inoperable
		// with no way for the firmware to recover.
		//
		// Wipes:   /cache/*  (RNS identity + path cache)
		//          /destination_table  (RNS routing table)
		// Keeps:   eeprom_rom, eeprom_conf, eeprom_defaults  (provisioning)
		//          /transport_identity, /lxmf_identity  (node identity)
#ifdef FORMAT_FS_ON_BOOT
		{
			HEAD("FORMAT_FS_ON_BOOT: wiping routing/cache (EEPROM preserved)...", RNS::LOG_CRITICAL);
			int cache_count = 0;

			// Remove all files inside /cache/
			File cache_dir = InternalFS.open("/cache");
			if (cache_dir && cache_dir.isDirectory()) {
				File f = cache_dir.openNextFile();
				while (f) {
					char path[128];
					snprintf(path, sizeof(path), "/cache/%s", f.name());
					f.close();
					InternalFS.remove(path);
					cache_count++;
					f = cache_dir.openNextFile();
				}
				cache_dir.close();
			}

			// Remove RNS destination/routing table
			bool removed_dest = false;
			if (InternalFS.exists("/destination_table")) {
				InternalFS.remove("/destination_table");
				removed_dest = true;
			}

			Serial.printf("[FS-WIPE] removed %d cache file(s)%s\r\n",
				cache_count, removed_dest ? ", /destination_table" : "");
			HEAD("Wipe complete", RNS::LOG_CRITICAL);
		}
#endif
		// Guard against corrupted LittleFS — a corrupt filesystem can trigger
		// a fatal assertion in lfs.c during file writes (e.g., after reflashing
		// with a different firmware). Format preemptively if root dir is invalid.
		// Note: we format rather than reformat here because reading files from
		// a corrupt FS is unreliable. Identity files are restored from raw flash
		// backup in RNode_Firmware.ino after filesystem init completes.
		{
			File root = InternalFS.open("/");
			if (!root || !root.isDirectory()) {
				HEAD("Filesystem corrupt, formatting...", RNS::LOG_CRITICAL);
				InternalFS.format();
				if (!InternalFS.begin()) {
					ERROR("InternalFS re-mount failed after format");
					return false;
				}
			} else {
				root.close();
			}
		}
#elif FS_TYPE == FS_TYPE_FLASHFS
		// Initialize FlashFileSystem
		INFO("FlashFS mounting filesystem");
		if (!g_flash.begin(&g_RAK15001)) {
			ERROR("FlashFS failed to initialize");
			return false;
		}
		if (!FlashFS.begin(&g_flash)) {
			ERROR("FlashFS filesystem mount failed");
			return false;
		}
#endif
		// Ensure filesystem is writable and reformat if not
		RNS::Bytes test("test");
		if (write_file("/test", test) < 4) {
			HEAD("Failed to write test file, filesystem is being reformatted...", RNS::LOG_CRITICAL);
			//FS.format();
			reformat();
		}
		else {
			remove_file("/test");
		}

		// Ensure /cache directory exists
		FS.mkdir("/cache");

		// Prune cache if filesystem is getting full
		prune_cache();

		// Recover interrupted atomic writes for identity files
		const char* identity_files[] = { "/transport_identity", "/lxmf_identity" };
		for (const char* path : identity_files) {
			std::string tmp = std::string(path) + ".tmp";
			if (file_exists(tmp.c_str()) && !file_exists(path)) {
				rename_file(tmp.c_str(), path);
				WARNINGF("Recovered interrupted write: %s", path);
			} else if (file_exists(tmp.c_str())) {
				remove_file(tmp.c_str());
			}
		}
	}
	catch (std::exception& e) {
		//ERROR("FileSystem init Exception: " + std::string(e.what()));
		return false;
	}
	TRACE("Finished initializing");
	return true;
}

bool FileSystem::format() {
	INFO("Formatting filesystem...");
	try {
		if (!FS.format()) {
			ERROR("Format failed!");
			return false;
		}
		return true;
	}
	catch (std::exception& e) {
		ERROR("FileSystem reformat Exception: " + std::string(e.what()));
	}
	return false;
}

bool FileSystem::reformat() {
	INFO("Reformatting filesystem...");
	try {
		RNS::Bytes eeprom;
		read_file("/eeprom", eeprom);
		RNS::Bytes transport_identity;
		read_file("/transport_identity", transport_identity);
		RNS::Bytes lxmf_identity;
		read_file("/lxmf_identity", lxmf_identity);
		if (!FS.format()) {
			ERROR("Format failed!");
			return false;
		}
		if (eeprom) {
			write_file("/eeprom", eeprom);
		}
		if (transport_identity) {
			write_file("/transport_identity", transport_identity);
		}
		if (lxmf_identity) {
			write_file("/lxmf_identity", lxmf_identity);
		}
		return true;
	}
	catch (std::exception& e) {
		ERROR("FileSystem reformat Exception: " + std::string(e.what()));
	}
	return false;
}

#ifndef NDEBUG

void FileSystem::listDir(const char* dir, const char* prefix /*= ""*/) {
	Serial.print(prefix);
	std::string full_dir(dir);
	if (full_dir.compare("/") != 0) {
		full_dir += "/";
	}
	Serial.println(full_dir.c_str());
	std::string pre(prefix);
	pre.append("  ");
	try {
		File root = FS.open(dir);
		if (!root) {
			Serial.print(pre.c_str());
			Serial.println("(failed to open directory)");
			return;
		}
		File file = root.openNextFile();
		while (file) {
			char* name = (char*)file.name();
			std::string recurse_dir(full_dir);
			if (file.isDirectory()) {
				recurse_dir += name;
				listDir(recurse_dir.c_str(), pre.c_str());
			}
			else {
				Serial.print(pre.c_str());
				//Serial.print("FILE: ");
				Serial.print(name);
				Serial.print(" (");
				Serial.print(file.size());
				Serial.println(" bytes)");
			}
			file.close();
			file = root.openNextFile();
		}
		root.close();
	}
	catch (std::exception& e) {
		Serial.print("listDir Exception: ");
		Serial.println(e.what());
	}
}

void FileSystem::dumpDir(const char* dir) {
	Serial.print("DIR: ");
	std::string full_dir(dir);
	if (full_dir.compare("/") != 0) {
		full_dir += "/";
	}
	Serial.println(full_dir.c_str());
	try {
		File root = FS.open(dir);
		if (!root) {
			Serial.println("(failed to open directory)");
			return;
		}
		File file = root.openNextFile();
		while (file) {
			char* name = (char*)file.name();
			if (file.isDirectory()) {
				std::string recurse_dir(full_dir);
				recurse_dir += name;
				dumpDir(recurse_dir.c_str());
			}
			else {
				Serial.print("\nFILE: ");
				Serial.print(name);
				Serial.print(" (");
				Serial.print(file.size());
				Serial.println(" bytes)");
				char data[4096];
				size_t size = file.size();
				size_t read = file.readBytes(data, (size < sizeof(data)) ? size : sizeof(data));
				Serial.write(data, read);
				Serial.println("");
			}
			file.close();
			file = root.openNextFile();
		}
		root.close();
	}
	catch (std::exception& e) {
		Serial.print("dumpDir Exception: ");
		Serial.println(e.what());
	}
}

#endif


/*virtua*/ bool FileSystem::file_exists(const char* file_path) {
	std::string safe_path = truncate_filename(file_path);
	file_path = safe_path.c_str();
	TRACEF("file_exists: checking for existence of file %s", file_path);
/*
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	File file(FS);
	if (file.open(file_path, FILE_O_READ)) {
#else
	File file = FS.open(file_path, FILE_READ);
	if (file) {
#endif
		bool is_directory = file.isDirectory();
		file.close();
		return !is_directory;
	}
	return false;
*/
	return FS.exists(file_path);
}

/*virtua*/ size_t FileSystem::read_file(const char* file_path, RNS::Bytes& data) {
	TRACEF("read_file: reading from file %s", file_path);
	std::string safe_path = truncate_filename(file_path);
	file_path = safe_path.c_str();
	size_t read = 0;
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	File file(FS);
	if (file.open(file_path, FILE_O_READ)) {
#else
	File file = FS.open(file_path, FILE_READ);
	if (file) {
#endif
		size_t size = file.size();
		read = file.readBytes((char*)data.writable(size), size);
		TRACEF("read_file: read %u bytes from file %s", read, file_path);
		if (read != size) {
			ERRORF("read_file: failed to read file %s", file_path);
            data.resize(read);
		}
		//TRACE("read_file: closing input file");
		file.close();
	}
	else {
		ERRORF("read_file: failed to open input file %s", file_path);
	}
    return read;
}

// Atomic write: write to .tmp then rename. Power-safe for critical files.
size_t FileSystem::write_file_atomic(const char* file_path, const RNS::Bytes& data) {
	std::string tmp_path = std::string(file_path) + ".tmp";
	TRACEF("write_file_atomic: writing to %s via %s", file_path, tmp_path.c_str());

	// Write to temp file first
	if (FS.exists(tmp_path.c_str())) {
		FS.remove(tmp_path.c_str());
	}
	size_t wrote = 0;
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	File file(FS);
	if (file.open(tmp_path.c_str(), FILE_O_WRITE)) {
#else
	File file = FS.open(tmp_path.c_str(), FILE_WRITE, true);
	if (file) {
#endif
		wrote = file.write(data.data(), data.size());
		file.close();
	}
	if (wrote < data.size()) {
		WARNINGF("write_file_atomic: temp write failed for %s", file_path);
		FS.remove(tmp_path.c_str());
		return 0;
	}

	// Rename temp to target (if power lost here, .tmp recovery handles it on boot)
	if (FS.exists(file_path)) {
		FS.remove(file_path);
	}
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	// InternalFS uses LittleFS rename
	if (InternalFS.rename(tmp_path.c_str(), file_path)) {
#else
	if (FS.rename(tmp_path.c_str(), file_path)) {
#endif
		TRACEF("write_file_atomic: %s updated (%u bytes)", file_path, wrote);
	} else {
		WARNINGF("write_file_atomic: rename failed, falling back to direct write for %s", file_path);
		FS.remove(tmp_path.c_str());
		return write_file_direct(file_path, data);
	}
	return wrote;
}

// Direct (non-atomic) write — the original implementation
size_t FileSystem::write_file_direct(const char* file_path, const RNS::Bytes& data) {
	TRACEF("write_file_direct: writing to file %s", file_path);
	if (FS.exists(file_path)) {
		FS.remove(file_path);
	}
	size_t wrote = 0;
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	File file(FS);
	if (file.open(file_path, FILE_O_WRITE)) {
#else
	File file = FS.open(file_path, FILE_WRITE, true);
	if (file) {
#endif
		wrote = file.write(data.data(), data.size());
        TRACEF("write_file_direct: wrote %u bytes to file %s", wrote, file_path);
        if (wrote < data.size()) {
			WARNINGF("write_file_direct: not all data was written to file %s", file_path);
		}
		file.close();
	}
	else {
		ERRORF("write_file_direct: failed to open output file %s", file_path);
	}
    return wrote;
}

/*virtua*/ size_t FileSystem::write_file(const char* file_path, const RNS::Bytes& data) {
	std::string safe_path = truncate_filename(file_path);
	file_path = safe_path.c_str();

	// Use atomic write for identity files (power-safe)
	if (safe_path.find("_identity") != std::string::npos) {
		return write_file_atomic(file_path, data);
	}

	// Prune cache if filesystem is getting full before cache writes
	if (safe_path.find("/cache/") != std::string::npos) {
		prune_cache();
	}

    return write_file_direct(file_path, data);
}

/*virtual*/ RNS::FileStream FileSystem::open_file(const char* file_path, RNS::FileStream::MODE file_mode) {
	std::string safe_path = truncate_filename(file_path);
	file_path = safe_path.c_str();
	TRACEF("open_file: opening file %s", file_path);
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	int mode;
	if (file_mode == RNS::FileStream::MODE_READ) {
		mode = FILE_O_READ;
	}
	else if (file_mode == RNS::FileStream::MODE_WRITE) {
		mode = FILE_O_WRITE;
		// CBA TODO Replace remove with working truncation
		if (FS.exists(file_path)) {
			FS.remove(file_path);
		}
	}
	else if (file_mode == RNS::FileStream::MODE_APPEND) {
		// CBA This is the default write mode for nrf52 littlefs
		mode = FILE_O_WRITE;
	}
	else {
		ERRORF("open_file: unsupported mode %d", file_mode);
		return {RNS::Type::NONE};
	}
	File* file = new File(FS);
	RNS::FileStream stream(new FileStream(file));
	if (!file->open(file_path, mode)) {
		ERRORF("open_file: failed to open output file %s", file_path);
		return {RNS::Type::NONE};
	}
	// Seek to beginning to overwrite (this is failing on nrf52)
	//if (file_mode == RNS::FileStream::MODE_WRITE) {
	//	file->seek(0);
	//	file->truncate(0);
	//}
	TRACEF("open_file: successfully opened file %s", file_path);
	return stream;
#else
	const char* mode;
	if (file_mode == RNS::FileStream::MODE_READ) {
		mode = FILE_READ;
	}
	else if (file_mode == RNS::FileStream::MODE_WRITE) {
		mode = FILE_WRITE;
	}
	else if (file_mode == RNS::FileStream::MODE_APPEND) {
		mode = FILE_APPEND;
	}
	else {
		ERRORF("open_file: unsupported mode %d", file_mode);
		return {RNS::Type::NONE};
	}
	TRACEF("open_file: opening file %s in mode %s", file_path, mode);
	// CBA Using copy constructor to obtain File*
	bool create = (file_mode == RNS::FileStream::MODE_WRITE || file_mode == RNS::FileStream::MODE_APPEND);
	File* file = new File(FS.open(file_path, mode, create));
	if (file == nullptr || !(*file)) {
		ERRORF("open_file: failed to open output file %s", file_path);
		delete file;
		return {RNS::Type::NONE};
	}
	TRACEF("open_file: successfully opened file %s", file_path);
	return RNS::FileStream(new FileStream(file));
#endif
}

/*virtua*/ bool FileSystem::remove_file(const char* file_path) {
	std::string safe_path = truncate_filename(file_path);
	file_path = safe_path.c_str();
	TRACEF("remove_file: removing file %s", file_path);
	return FS.remove(file_path);
}

/*virtua*/ bool FileSystem::rename_file(const char* from_file_path, const char* to_file_path) {
	std::string safe_from = truncate_filename(from_file_path);
	std::string safe_to = truncate_filename(to_file_path);
	from_file_path = safe_from.c_str();
	to_file_path = safe_to.c_str();
	TRACEF("rename_file: renaming file %s to %s", from_file_path, to_file_path);
	return FS.rename(from_file_path, to_file_path);
}

/*virtua*/ bool FileSystem::directory_exists(const char* directory_path) {
	TRACEF("directory_exists: checking for existence of directory %s", directory_path);
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	File file(FS);
	if (file.open(directory_path, FILE_O_READ)) {
#else
	File file = FS.open(directory_path, FILE_READ);
	if (file) {
#endif
		bool is_directory = file.isDirectory();
		file.close();
		return is_directory;
	}
	return false;
}

/*virtua*/ bool FileSystem::create_directory(const char* directory_path) {
	TRACEF("create_directory: creating directory %s", directory_path);
	if (!FS.mkdir(directory_path)) {
		ERROR("create_directory: failed to create directory " + std::string(directory_path));
		return false;
	}
	return true;
}

/*virtua*/ bool FileSystem::remove_directory(const char* directory_path) {
	TRACEF("remove_directory: removing directory %s", directory_path);
#if FS_TYPE == FS_TYPE_INTERNALFS || FS_TYPE == FS_TYPE_FLASHFS
	if (!FS.rmdir_r(directory_path)) {
#else
	if (!FS.rmdir(directory_path)) {
#endif
		ERROR("remove_directory: failed to remove directory " + std::string(directory_path));
		return false;
	}
	return true;
}

/*virtua*/ std::list<std::string> FileSystem::list_directory(const char* directory_path, Callbacks::DirectoryListing callback /*= nullptr*/) {
	TRACEF("list_directory: listing directory %s", directory_path);
	std::list<std::string> files;
	File root = FS.open(directory_path);
	if (!root) {
		ERROR("list_directory: failed to open directory " + std::string(directory_path));
		return files;
	}
	File file = root.openNextFile();
	while (file) {
		if (!file.isDirectory()) {
			char* name = (char*)file.name();
			files.push_back(name);
		}
		// CBA Following close required to avoid leaking memory
		file.close();
		file = root.openNextFile();
	}
	root.close();
	TRACE("list_directory: returning directory listing");
	return files;
}

/*virtual*/ size_t FileSystem::storage_size() {
#if FS_TYPE == FS_TYPE_INTERNALFS
	return totalBytes();
#else
	return FS.totalBytes();
#endif
}

/*virtual*/ size_t FileSystem::storage_available() {
#if FS_TYPE == FS_TYPE_INTERNALFS
	return (totalBytes() - usedBytes());
#else
	return (FS.totalBytes() - FS.usedBytes());
#endif
}

void FileSystem::prune_cache() {
	size_t total = storage_size();
	if (total == 0) return;
	size_t threshold = total / 7; // ~15% free
	size_t available = storage_available();
	if (available >= threshold) return;

	std::list<std::string> files = list_directory("/cache");
	size_t removed = 0;
	for (auto& name : files) {
		if (storage_available() >= threshold) break;
		std::string path = "/cache/" + name;
		remove_file(path.c_str());
		removed++;
	}
	if (removed > 0) {
		WARNINGF("Pruned %zu cache files, %zu bytes free", removed, storage_available());
	}
}

#endif
