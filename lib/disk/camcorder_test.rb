require 'openssl' # Required for 'Digest' in camcorder (< Ruby 2.1)?
require 'camcorder'
require 'ostruct'
require 'disk/MiqDisk'
require 'disk/modules/MiqLargeFile'

require 'logger'
$log = Logger.new(STDERR)
$log.level = Logger::DEBUG

#
# Path to RAW disk image.
#
VIRTUAL_DISK_FILE = "path to raw disk image file"

commit = true

begin
  recorder = Camcorder::Recorder.new("#{File.dirname(__FILE__)}/foo.yml")
  Camcorder.default_recorder = recorder
  Camcorder.intercept_constructor(MiqLargeFile::MiqLargeFileOther) do
    methods_with_side_effects :seek, :read, :write
  end

  recorder.start

  diskInfo = OpenStruct.new
  diskInfo.rawDisk = true
  diskInfo.fileName = VIRTUAL_DISK_FILE
  #
  # When the target VIRTUAL_DISK_FILE doesn't exist - when running the test from
  # the recording, for example - some of the probe routines return false positive.
  #
  # We constrain the probing here, so the test will run properly in the absence
  # of the disk file.
  #
  disk = MiqDisk.getDisk(diskInfo, "RawDiskProbe")

  unless disk
    puts "Failed to open disk"
    exit(1)
  end

  puts "Disk type: #{disk.diskType}"
  puts "Disk partition type: #{disk.partType}"
  puts "Disk block size: #{disk.blockSize}"
  puts "Disk start LBA: #{disk.lbaStart}"
  puts "Disk end LBA: #{disk.lbaEnd}"
  puts "Disk start byte: #{disk.startByteAddr}"
  puts "Disk end byte: #{disk.endByteAddr}"

  parts = disk.getPartitions

  exit(0) unless parts

  i = 1
  parts.each do |p|
    puts "\nPartition #{i}:"
    puts "\tDisk type: #{p.diskType}"
    puts "\tPart partition type: #{p.partType}"
    puts "\tPart block size: #{p.blockSize}"
    puts "\tPart start LBA: #{p.lbaStart}"
    puts "\tPart end LBA: #{p.lbaEnd}"
    puts "\tPart start byte: #{p.startByteAddr}"
    puts "\tPart end byte: #{p.endByteAddr}"
    i += 1
  end
rescue => err
  puts err.to_s
  puts err.backtrace.join("\n")
  commit = false # don't commit recording on error
ensure
  disk.close if disk
  if recorder && commit
    puts
    puts "camcorder: committing recording..."
    recorder.commit
    puts "done."
  end
end
