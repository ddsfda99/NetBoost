import { runBatch } from '../../common/Runner';
import common from '@ohos.app.ability.common';

// 只用WiFi（基线）和WiFi、蜂窝自动切换（优化）
enum Mode {
  WIFI_ONLY = 'WIFI_ONLY',
  AUTO_SWITCH = 'AUTO_SWITCH',
}

@Entry
@Component
struct Index {
  @State baseUrl: string = 'http://139.224.130.188/images';
  @State count: number = 50;
  @State running: boolean = false;
  @State output: string = '';
  @State mode: Mode = Mode.AUTO_SWITCH;

  build() {
    Column() {
      Text('NetBench').fontSize(22).margin({ bottom: 16 })

      // Base URL：输入图片资源的路径
      TextInput({ text: this.baseUrl, placeholder: 'Base URL' })
        .onChange(v => this.baseUrl = v)
        .margin({ bottom: 8 })

      // Count：输入需要下载的文件数量
      TextInput({ text: String(this.count), placeholder: 'Count' })
        .type(InputType.Number)
        .onChange(v => {
          const n = Number(v);
          if (!isNaN(n)) this.count = n;
        })
        .margin({ bottom: 16 })

      // 模式选择
      Row() {
        Button(this.mode === Mode.WIFI_ONLY ? '✓ Wi-Fi Only' : 'Wi-Fi Only')
          .onClick(() => this.mode = Mode.WIFI_ONLY)
          .margin({ right: 8 })
        Button(this.mode === Mode.AUTO_SWITCH ? '✓ Auto Switch' : 'Auto Switch')
          .onClick(() => this.mode = Mode.AUTO_SWITCH)
      }.margin({ bottom: 16 })

      // Run 按钮
      Button(this.running ? 'Running...' : 'Run x5')
        .enabled(!this.running)
        .onClick(async () => {
          this.running = true;
          const lines: string[] = [];
          const ctx = getContext(this) as common.UIAbilityContext;
          for (let i = 1; i <= 5; i++) {
            try {
              const r = await runBatch(this.baseUrl, this.count, this.mode, ctx);
              lines.push(
                `round=${i} mode=${this.mode} time=${r.totalTime.toFixed(3)}s bytes=${(r.totalBytes / 1048576).toFixed(2)}MB`
              );
            } catch (err) {
              lines.push(`round=${i} mode=${this.mode} error=${err}`);
            }
          }
          this.output = lines.join('\n');
          this.running = false;
        })
        .margin({ bottom: 16 })

      Scroll() {
        Text(this.output).fontFamily('monospace')
      }.height('60%').width('100%')
    }.padding(16).width('100%')
  }
}
