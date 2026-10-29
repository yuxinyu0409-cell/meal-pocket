import Foundation
@main struct CoreTests {
 static func main() throws {
  assert(Money.cents("23.45") == 2345)
  assert(Money.cents("0.01") == 1)
  assert(Money.cents("12.345") == nil)
  assert(Money.cents("-1") == nil)
  let a = ReceiptParser.parse("某某餐厅\n2026-10-27 12:00\n商品总价 ¥35.00\n实付款 ¥28.50")
  assert(a.amountCents == 2850)
  assert(a.date != nil)
  let b = ReceiptParser.parse("小票\n合计 20.00")
  assert(b.date == nil)
  assert(b.amountCents == 2000)
  let c = ReceiptParser.parse("商品 30.00\n优惠 5.00")
  assert(c.amountCents == nil)
  let d = ReceiptParser.parse("日期 2026-02-31\n实付 19.00")
  assert(d.date == nil)
  assert(ReceiptParser.parse("测试餐厅\n实付金额 ¥28").amountCents == 2800)
  assert(ReceiptParser.parse("2026年10月28日\n实付款 ¥28.50").merchant.isEmpty)
  assert(ReceiptParser.parse("测试餐厅\n实付款 ¥28.50\n实付款 ¥36.50").amountConflict)
  assert(ReceiptParser.parse("测试餐厅\n2026-10-27\n2026-10-28\n实付 ¥28.50").dateConflict)
  let encoder = JSONEncoder(); let decoder = JSONDecoder()
  let record = MealRecord(merchant:"测试", date:Date(), amountCents:1234)
  let decoded = try decoder.decode(MealRecord.self, from:encoder.encode(record))
  assert(decoded.amountCents == 1234)
  assert(ReportLayout.sliceHeights(width:400,height:4000,pageWidth:500,pageHeight:650).count == 8)
  let date = a.date!
  let sameDay = [MealRecord(merchant:"A",date:date,amountCents:2200),MealRecord(merchant:"B",date:date,amountCents:1800)]
  assert(Reimbursement.total(sameDay) == 3000)
  let tomorrow = Calendar.current.date(byAdding:.day,value:1,to:date)!
  assert(Reimbursement.total(sameDay + [MealRecord(merchant:"C",date:tomorrow,amountCents:1500)]) == 4500)
  assert(Reimbursement.validTime("22:05") && !Reimbursement.validTime("24:01") && !Reimbursement.validTime("22:99"))
  let old = Data(#"{"version":1,"meals":[],"exports":[]}"#.utf8)
  let migrated = try decoder.decode(Archive.self,from:old)
  assert(migrated.meals.isEmpty && migrated.profile == nil && migrated.dayTimes == nil)
  let workbook = SpreadsheetExporter.workbook(records:sameDay,profile:PersonalProfile(name:"本人<&",department:"研发部"),times:[Reimbursement.day(date):"22:05"])
  try workbook.write(to:URL(fileURLWithPath:"/tmp/meal-test.xlsx"))
  var admitted = MealRecord()
  admitted.attachments = [ReceiptAttachment(filename:"test.png",hash:"test",text:"示例餐厅\n2026-10-28\n实付款 ¥28.50")]
  ReceiptAdmission.apply(to:&admitted)
  assert(admitted.confirmed && admitted.amountCents == 2850)
  admitted.attachments = [ReceiptAttachment(filename:"test.png",hash:"test",text:"示例餐厅\n2026-10-28")]
  ReceiptAdmission.apply(to:&admitted)
  assert(!admitted.confirmed && admitted.reviewReasons.contains("实付金额未识别"))
  admitted.attachments = [ReceiptAttachment(filename:"test.png",hash:"test",text:"示例餐厅\n2026-10-28\n实付款 ¥28.50"),ReceiptAttachment(filename:"test2.png",hash:"test2",text:"示例餐厅\n2026-10-28\n实付款 ¥36.50")]
  ReceiptAdmission.apply(to:&admitted)
  assert(!admitted.confirmed && admitted.reviewReasons.contains("实付金额有冲突"))
  let selectedBefore:Set<UUID> = [sameDay[0].id]
  assert(ReportSelection.reconcile(current:selectedBefore,eligible:sameDay,submitted:[],userChanged:true) == selectedBefore)
  assert(ReportSelection.reconcile(current:[],eligible:sameDay,submitted:[sameDay[0].id],userChanged:false) == [sameDay[1].id])
  print("PASS: paid integer amounts, single-image amount/date conflicts, selection preserved")
  print("PASS: complete OCR auto-admission, incomplete OCR manual queue, conflict queue")
  print("PASS: daily reimbursement cap, shared civil date, time validation, legacy archive migration, workbook generation;")
  print("PASS: amount precision, OCR priorities, missing and invalid dates, Codable, long-image pagination")
 }
}
