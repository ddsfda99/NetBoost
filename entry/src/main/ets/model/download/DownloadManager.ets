// 下载管理器：管理所有下载任务并进行并发下载
import { DownloadTask } from './DownloadTask';

export class DownloadManager {
  private downloadTasks: DownloadTask[] = [];

  public addDownloadTask(task: DownloadTask): void {
    this.downloadTasks.push(task);
  }

  public async startDownload(): Promise<void> {
    // 启动所有下载任务的下载
    for (const task of this.downloadTasks) {
      await task.start();
    }
  }
}
