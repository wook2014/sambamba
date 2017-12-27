/*
    New style BGZF writer. This file is part of Sambamba.
    Copyright (C) 2017 Pjotr Prins <pjotr.prins@thebird.nl>

    Sambamba is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published
    by the Free Software Foundation; either version 2 of the License,
    or (at your option) any later version.

    Sambamba is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
    02111-1307 USA

*/

// Based on the original by Artem Tarasov.

module sambamba.bio2.bgzf_writer;

import core.stdc.stdlib : malloc, free;
import core.stdc.stdio: fopen, fread, fclose;
import std.conv;
import std.exception;
import std.typecons;
import std.parallelism;
import std.array;
import std.algorithm : max;
import std.stdio;
import std.typecons;

import bio.core.bgzf.compress;
import bio.core.utils.roundbuf;

// import undead.stream;

import bio.bam.constants: BGZF_MAX_BLOCK_SIZE, BGZF_BLOCK_SIZE, BGZF_EOF;
import sambamba.bio2.bgzf;
import sambamba.bio2.constants;

alias void delegate(ubyte[], ubyte[]) BlockWriteHandler;

Tuple!(ubyte[], ubyte[], BlockWriteHandler)
bgzfCompressFunc(ubyte[] input, int level, ubyte[] output_buffer,
                 BlockWriteHandler handler)
{
  auto output = bgzfCompress(input, level, output_buffer);
  return tuple(input, output, handler);
}

/// BGZF compression - this is a port of the original that used the
/// undead.stream library.
struct BgzfWriter {

private:
  File f;
  TaskPool task_pool;

  ubyte[] _buffer; // a slice into _compression_buffer (uncompressed data)
  ubyte[] _tmp;    // a slice into _compression_buffer (compressed data)
  size_t _current_size;
  int _compression_level;

  alias Task!(bgzfCompressFunc,
              ubyte[], int, ubyte[], BlockWriteHandler) CompressionTask;
  RoundBuf!(CompressionTask*) _compression_tasks;
  ubyte[] _compression_buffer;

public:

  /// Create new BGZF output stream with a multi-threaded writer
  this(string fn, int compression_level=-1) {
    f = File(fn,"r");
    enforce1(-1 <= compression_level && compression_level <= 9,
            "BGZF compression level must be a number in interval [-1, 9]");
    size_t max_block_size= BGZF_MAX_BLOCK_SIZE;
    size_t block_size    = BGZF_BLOCK_SIZE;
    task_pool   = taskPool(),
    _compression_level = compression_level;

    // create a ring buffer that is large enough
    size_t n_tasks = max(task_pool.size, 1) * 16;
    _compression_tasks = RoundBuf!(CompressionTask*)(n_tasks);

    // create extra block to which we can write while n_tasks are
    // executed
    auto comp_buf_size = (2 * n_tasks + 2) * max_block_size;
    auto p = cast(ubyte*)malloc(comp_buf_size);
    _compression_buffer = p[0 .. comp_buf_size];
    _buffer = _compression_buffer[0 .. block_size];
    _tmp = _compression_buffer[max_block_size .. max_block_size * 2];
  }

  @disable this(this); // BgzfWriter does not have copy semantics;

  void throwBgzfException(string msg, string file = __FILE__, size_t line = __LINE__) {
    throw new BgzfException("Error writing BGZF block starting in "~f.name ~
                            " (" ~ file ~ ":" ~ to!string(line) ~ "): " ~ msg);
  }

  void enforce1(bool check, lazy string msg, string file = __FILE__, int line = __LINE__) {
    if (!check)
      throwBgzfException(msg,file,line);
  }

  size_t write(const void* buf, size_t size) {
    if (size + _current_size >= _buffer.length) {
      size_t room;
      ubyte[] data = (cast(ubyte*)buf)[0 .. size];

      while (data.length + _current_size >= _buffer.length) {
        room = _buffer.length - _current_size;
        _buffer[$ - room .. $] = data[0 .. room];
        data = data[room .. $];

        _current_size = _buffer.length;

        flush_block();
      }

      _buffer[0 .. data.length] = data[];
      _current_size = data.length;
    } else {
      _buffer[_current_size .. _current_size + size] = (cast(ubyte*)buf)[0 .. size];
      _current_size += size;
    }

    return size;
  }

  /// Force flushing current block, even if it is not yet filled.
  /// Should also be used when it's not desired to have records
  /// crossing block borders.
  void flush_block() {
    if (_current_size == 0)
      return;

    Tuple!(ubyte[], ubyte[], BlockWriteHandler) front_result;
    if (_compression_tasks.full) {
      front_result = _compression_tasks.front.yieldForce();
      _compression_tasks.popFront();
    }

    auto compression_task = task!bgzfCompressFunc(_buffer[0 .. _current_size],
                                                  _compression_level, _tmp,
                                                  _before_write);
    _compression_tasks.put(compression_task);
    task_pool.put(compression_task);

    size_t offset = _buffer.ptr - _compression_buffer.ptr;
    immutable N = _tmp.length;
    offset += 2 * N;
    if (offset == _compression_buffer.length)
      offset = 0;
    _buffer = _compression_buffer[offset .. offset + _buffer.length];
    _tmp = _compression_buffer[offset + N .. offset + 2 * N];
    _current_size = 0;

    if (front_result[0] !is null)
      writeResult(front_result);

    while (!_compression_tasks.empty) {
      auto task = _compression_tasks.front;
      if (!task.done())
        break;
      auto result = task.yieldForce();
      writeResult(result);
      _compression_tasks.popFront();
    }
  }

  private void delegate(ubyte[], ubyte[]) _before_write;
  void setWriteHandler(void delegate(ubyte[], ubyte[]) handler) {
    _before_write = handler;
  }

  private void writeResult(Tuple!(ubyte[], ubyte[], BlockWriteHandler) block) {
    auto uncompressed = block[0];
    auto compressed = block[1];
    auto handler = block[2];
    if (handler) {// write handler enabled
      handler(uncompressed, compressed);
    }
    // _stream.writeExact(compressed.ptr, compressed.length);
    f.rawWrite(compressed);
  }

  /// Flush all remaining BGZF blocks and underlying stream.
  void flush() {
    flush_block();

    while (!_compression_tasks.empty) {
      auto task = _compression_tasks.front;
      auto block = task.yieldForce();
      writeResult(block);
      _compression_tasks.popFront();
    }

    f.flush();
    _current_size = 0;
  }

  /// Flush all remaining BGZF blocks and close source stream.
  /// Automatically adds empty block at the end, serving as indicator
  /// of end of stream. Make sure this function is called on
  /// completion.
  void close() {
    flush();
    f.rawWrite(BGZF_EOF);
    f.close();
    free(_compression_buffer.ptr);
  }
}
