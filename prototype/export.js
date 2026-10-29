/* Browser-only PDF, OOXML workbook and ZIP generation. No receipt uploads. */
(() => {
  'use strict';
  const xml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
  const money = cents => (cents / 100).toFixed(2);
  function days(report) {
    const grouped = new Map();
    for (const record of report.records) {
      if (!grouped.has(record.date)) grouped.set(record.date, []);
      grouped.get(record.date).push(record);
    }
    return [...grouped].sort(([a], [b]) => a.localeCompare(b));
  }
  async function workbook(report) {
    const rows = [['日期','报销人','部门','加班结束时间','晚餐餐补（元）','住宿费（元）','备注']];
    let dinner = 0, lodging = 0;
    for (const [date, records] of days(report)) {
      const meal = Math.min(3000, records.reduce((sum, record) => sum + record.cents, 0));
      const stay = report.lodging[date] || 0;
      dinner += meal; lodging += stay;
      rows.push([date,report.profile.name,report.profile.department,report.times[date],{number:money(meal)},{number:money(stay)},records.map(r => r.note || '').filter(Boolean).join('；')]);
    }
    rows.push(['合计','','','',{number:money(dinner)},{number:money(lodging)},'']);
    const sheet = rows.map((row,i) => `<row r="${i+1}">${row.map((value,j) => {
      const cell = `${String.fromCharCode(65+j)}${i+1}`;
      return value && typeof value === 'object' ? `<c r="${cell}" s="1"><v>${value.number}</v></c>` : `<c r="${cell}" t="inlineStr"><is><t xml:space="preserve">${xml(value)}</t></is></c>`;
    }).join('')}</row>`).join('');
    const zip = new JSZip();
    const add = (name,body) => zip.file(name,'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+body);
    add('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>');
    add('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
    add('xl/workbook.xml','<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="晚餐报销明细" sheetId="1" r:id="rId1"/></sheets></workbook>');
    add('xl/_rels/workbook.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>');
    add('xl/styles.xml','<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="宋体"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>');
    add('xl/worksheets/sheet1.xml',`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="7" width="22" customWidth="1"/></cols><sheetData>${sheet}</sheetData></worksheet>`);
    return zip.generateAsync({type:'uint8array',compression:'DEFLATE'});
  }
  function loadImage(src) {
    return new Promise((resolve,reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error('有图片无法读取，请检查原图后重新生成。'));
      image.src = src;
    });
  }
  async function pdf(report) {
    const doc = await PDFLib.PDFDocument.create();
    doc.setTitle('餐费小袋 · 餐费票据');
    doc.setCreator('餐费小袋');
    for (const kind of ['delivery','dine']) {
      const images = report.records.filter(r => r.kind === kind).sort((a,b) => a.date.localeCompare(b.date))
        .flatMap(r => r.images.map((src,index) => ({record:r,src,index})));
      for (let offset=0; offset<images.length; offset+=4) {
        const canvas = document.createElement('canvas'); canvas.width=1190; canvas.height=1684;
        const ctx = canvas.getContext('2d');
        if (!ctx) throw new Error('当前浏览器无法绘制票据，请换用较新的浏览器。');
        ctx.fillStyle='#fff'; ctx.fillRect(0,0,1190,1684);
        ctx.fillStyle='#25252c'; ctx.font='bold 42px sans-serif';
        ctx.fillText(kind === 'delivery' ? '外卖截图' : '堂食小票',72,104);
        ctx.font='22px sans-serif'; ctx.fillStyle='#666';
        ctx.fillText(`${report.month} · ${report.profile.name} · ${report.profile.department}`,72,152,1046);
        for (let index=0; index<Math.min(4,images.length-offset); index++) {
          const item=images[offset+index], image=await loadImage(item.src);
          const x=72+(index%2)*538, y=210+Math.floor(index/2)*690;
          const scale=Math.min(508/image.naturalWidth,570/image.naturalHeight);
          const width=image.naturalWidth*scale,height=image.naturalHeight*scale;
          ctx.drawImage(image,x+(508-width)/2,y,width,height);
          ctx.fillStyle='#25252c'; ctx.font='bold 22px sans-serif';
          ctx.fillText(item.record.merchant,x,y+600,508);
          ctx.fillStyle='#666'; ctx.font='19px sans-serif';
          ctx.fillText(`${item.record.date} · 实付 ¥${money(item.record.cents)} · 凭证 ${item.index+1}`,x,y+630,508);
        }
        ctx.font='18px sans-serif'; ctx.fillStyle='#888';
        ctx.fillText(`餐费小袋 · 第 ${doc.getPageCount()+1} 页 · 原图每页最多四张`,72,1640);
        const image=await doc.embedJpg(canvas.toDataURL('image/jpeg',0.94));
        doc.addPage([595,842]).drawImage(image,{x:0,y:0,width:595,height:842});
        await new Promise(resolve => setTimeout(resolve,0));
      }
    }
    if (!doc.getPageCount()) throw new Error('没有可导出的票据图片。');
    return doc.save();
  }
  async function build(report) {
    if (!window.JSZip || !window.PDFLib) throw new Error('导出组件尚未加载，请刷新后重试。');
    const [pdfBytes,xlsxBytes]=await Promise.all([pdf(report),workbook(report)]);
    const zip=new JSZip(), stem=report.month;
    zip.file(`${stem}餐费票据.pdf`,pdfBytes);
    zip.file(`${stem}报销明细.xlsx`,xlsxBytes);
    for (const [index,invoice] of report.invoices.entries()) {
      if (invoice.demo || !invoice.data) continue;
      const match=/^data:[^,]*;base64,(.*)$/s.exec(invoice.data);
      if (!match) throw new Error('发票原件无法读取，请重新添加。');
      const name=invoice.name.replace(/[\\/]/g,'_');
      zip.file(`发票原件/${index+1}-${name}`,match[1],{base64:true});
    }
    zip.file('使用说明.txt','餐费小袋\n票据 PDF：按外卖、堂食分类，每页最多四张图片。\n报销明细：每天晚餐合计最高30元，同日仅计算一次，住宿费另列。\n示例票据标注“示例”，不能用于实际报销。\n示例发票不作为真实发票原件打包；自行添加的发票保留原文件。\n');
    return {pdf:pdfBytes,xlsx:xlsxBytes,zip:await zip.generateAsync({type:'blob',compression:'DEFLATE'})};
  }
  function download(blob,name) {
    const url=URL.createObjectURL(blob),a=document.createElement('a');
    a.href=url; a.download=name; document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url),60000);
  }
  window.MealExport={build,workbook,download};
})();
