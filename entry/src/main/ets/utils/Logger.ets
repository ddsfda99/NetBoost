// 轻量日志工具：既打印到控制台，也可让 UI 选择性接收
type LogSink = (line: string) => void;

class _Logger {
  private sinks: LogSink[] = [];

  addSink(sink: LogSink) {
    this.sinks.push(sink);
  }
  removeSink(sink: LogSink) {
    this.sinks = this.sinks.filter(s => s !== sink);
  }

  log(msg: string) {
    const line = `${new Date().toLocaleTimeString()} ${msg}`;
    console.log(line);
    for (const s of this.sinks) s(line);
  }
}

export const Logger = new _Logger();
