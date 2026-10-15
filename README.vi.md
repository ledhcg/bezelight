<div align="center">

# Bezelight

**Ánh sáng nền cho màn hình của bạn.** Ứng dụng macOS native, nhỏ gọn, mã nguồn mở, điều khiển
dải LED USB sau màn hình, đồng bộ theo hình ảnh hoặc âm nhạc.

[English](README.md) · [Tiếng Việt](README.vi.md)

</div>

- **Rất nhẹ.** Đo trên M2 khi stream màn hình: khoảng 2% CPU lúc ẩn cửa sổ, 6% lúc mở, ~80 MB RAM;
  ~0% khi màn hình đứng yên. Chế độ màu tĩnh tắt hẳn việc chụp màn hình.
- **Giao diện Liquid Glass** của macOS 26 kèm xem trước trực tiếp từng LED; tự dùng vật liệu hệ thống
  trên macOS 14/15.
- **Màu chuẩn.** Mỗi LED lấy mẫu đúng vị trí thật trên dải, trung bình theo ánh sáng tuyến tính,
  hiệu chỉnh gamma cho LED, tự bỏ dải đen khi xem phim, chỉnh cân bằng trắng.
- **Hiệu ứng nhạc không cần micro.** Bass / trung / treble / phổ màu từ âm thanh hệ thống (ScreenCaptureKit + FFT).
  Không ghi âm, không lưu gì.
- **Hiệu ứng động:** Rainbow (4 bảng màu hoặc tự chọn), Breathing, Comet, Spectrum Cycling, Starry Night; **Equalizer** 16 dải.
  Các hiệu ứng này không cần quyền màn hình hay âm thanh.
- **Tự nhận diện phần cứng:** hỏi bộ điều khiển là model nào khi kết nối, tự chọn bố cục LED; nút "Kiểm tra bố cục".
- **Phím tắt toàn cục** (⌃⌥⇧F8 bật/tắt, F9 bật, F10 tắt, ↑/↓ độ sáng) và nút cứng trên thiết bị có nút.
- **Thông báo agent.** Dải đèn sáng khi Claude Code, Codex hoặc OpenCode cần bạn, làm xong hoặc gặp lỗi, với bao nhiêu phiên cùng lúc cũng được. Xem [Thông báo agent](#thông-báo-agent).
- **5 ngôn ngữ**, đổi tức thì: English, Tiếng Việt, 简体中文, 日本語, 한국어.
- **Điều khiển trên menu bar**, mở khi đăng nhập, nhiều màn hình, bố trí LED tùy chỉnh.

## Cài đặt

Tải `Bezelight.app` ở trang [Releases](../../releases), hoặc tự build:

```bash
git clone https://github.com/ledhcg/bezelight && cd bezelight
scripts/build-app.sh          # -> dist/Bezelight.app
open dist/Bezelight.app
```

Cần macOS 14+ và Xcode 15+ (Xcode 26 để có giao diện Liquid Glass).

## Sử dụng

1. Cắm bộ điều khiển, mở Bezelight, vào **Cài đặt** (⌘,) chọn **cổng serial** và **mẫu thiết bị**.
   Không có trong danh sách? Chọn *Bố trí tùy chỉnh* và nhập số LED mỗi cạnh.
2. Nhấn **Bắt đầu** (Space). Lần đầu macOS sẽ hỏi quyền *Ghi màn hình và âm thanh hệ thống*. Một quyền
   này dùng cho cả màu màn hình lẫn nhạc.
3. Chọn chế độ, chỉnh độ sáng, độ bão hòa, độ mượt. Đóng cửa sổ thì đèn vẫn chạy, điều khiển ở icon menu bar.
   Thoát app sẽ tắt đèn.

Nếu báo cổng *bận*, có chương trình khác đang dùng cổng (ví dụ app gốc của hãng). Hãy thoát nó trước.

## Thông báo agent

Bezelight có thể làm dải đèn sáng khi một agent lập trình AI cần bạn, làm xong hoặc gặp lỗi: **Claude Code**,
**Codex** và **OpenCode**, nhiều phiên cùng lúc. Tính năng tắt cho đến khi bạn cài đặt.

**Agent là một chế độ riêng**, cạnh Màn hình, Nhạc và Màu. Ở chế độ này dải đèn chỉ là đèn báo (tối, hoặc một màu
nền êm bạn chọn, cho đến khi có việc) và không cần màn hình hay âm thanh, nên không xin quyền Ghi màn hình. Ở các
chế độ khác sẽ không có gì được vẽ đè lên đèn của bạn, trừ khi bạn bật *Hiện thông báo cả ở các chế độ khác*.

| Thông báo | Mặc định | Giữ đến khi |
|---|---|---|
| **Cần bạn**: xin quyền hoặc hỏi một câu | hổ phách, nhịp thở | được trả lời |
| **Lỗi**: một lượt kết thúc với lỗi | đỏ | bạn quay lại |
| **Xong**: agent làm xong lúc bạn vắng | xanh lá mờ | bạn chạm bàn phím hoặc chuột |
| **Đang làm** (mặc định tắt) | xanh lơ, 10% đầu dải | còn đang làm |

Khi nhiều phiên cần chú ý, dải đèn hiện cái quan trọng nhất (cần bạn, rồi lỗi, rồi xong), và menu bar liệt kê
các phiên. Khi có nhiều phiên đang chờ, "Cần bạn" đổi sang nhịp đôi.

**Cài đặt.** Chọn chế độ **Agent** cạnh Màn hình, Nhạc và Màu. Các tuỳ chọn hiện ở cột bên phải như các chế độ
khác: nhấn *Cài cho các agent đã phát hiện* ở đó.

- **Claude Code**: thêm hook nhỏ vào `settings.json` của mọi thư mục Claude tìm thấy (`~/.claude` và từng
  `~/.claude-accounts/*`). Hãy khởi động lại các phiên đang mở: chúng chỉ đọc hook lúc khởi động.
- **Codex**: thêm hook vào `~/.codex/hooks.json`. Trong Codex gõ `/hooks` và tin cậy chúng.
- **OpenCode** (2.x): không cần cài gì. Bezelight tự nghe luồng sự kiện của OpenCode.

**An toàn từ thiết kế.** Không có gì rời khỏi máy và nội dung bạn gõ hay câu trả lời của agent không bao giờ
được đọc: chỉ loại sự kiện, mã phiên và tên thư mục đi qua một socket riêng trong `~/.bezelight`. Hook của
công cụ khác (như Orca) được giữ nguyên từng byte, có sao lưu trước lần thay đổi đầu tiên, và *Gỡ* trả tệp về
đúng như cũ. Nếu Bezelight không chạy, hook không làm gì và agent không hiện lỗi.

**Tùy chỉnh.** Với mỗi thông báo bạn đổi được màu, hiệu ứng mở đầu (nhấp nháy, nhịp mượt, lóe sáng), hiệu ứng
tiếp theo (sáng đều, thở, nhấp nháy, sao chổi), thời gian giữ, phần dải đèn dùng, có hiện khi đèn tắt không,
và áp dụng cho agent nào, kèm xem thử trực tiếp trên dải đèn. Mỗi lựa chọn đều có mô tả ngay bên cạnh.
⌃⌥⇧F11 bỏ qua các thông báo đang hiện.

**Trợ năng.** Nhấp nháy không bao giờ quá 3 lần mỗi giây, "Giảm nhấp nháy" (và *Giảm chuyển động* của macOS)
thay nhấp nháy bằng nhịp sáng chậm, và icon menu bar đổi hình dạng chứ không chỉ đổi màu.

**Nếu không thấy gì**, nhấn *Kiểm tra ngay* trong Thông báo agent: nó thử công cụ hook, socket và từng agent
rồi cho biết cần sửa gì. Nguyên nhân thường gặp: phiên đang mở chưa khởi động lại (Claude Code), hook chưa được
tin cậy (Codex, `/hooks`), hoặc hook cài ở thư mục Claude khác với thư mục bạn dùng (hãy cài cho mọi thư mục
bạn dùng). Đã kiểm chứng với Claude Code 2.1, Codex 0.162 và OpenCode 2.0.28; luồng sự kiện của OpenCode không
phải API công khai nên bản sau có thể cần cập nhật.

## Đóng góp

Báo lỗi, thêm mẫu thiết bị, bản dịch đều được chào đón. Bản dịch là file `.strings` thuần,
xem [CONTRIBUTING.md](CONTRIBUTING.md).

## Giấy phép

[MIT](LICENSE)
