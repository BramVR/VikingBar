from pathlib import Path
from reportlab.lib.colors import HexColor
from reportlab.pdfgen import canvas

output = Path(__file__).resolve().parent.parent / 'public' / 'assets'
for paid in (False, True):
    document = 'SAMPLE-2026-002' if paid else 'SAMPLE-2026-001'
    target = output / ('sample-invoice-paid.pdf' if paid else 'sample-invoice.pdf')
    pdf = canvas.Canvas(str(target), pagesize=(595, 842), invariant=1)
    pdf.setTitle(f'VikingBar demo invoice {document}')
    pdf.setAuthor('VikingBar')
    pdf.setFillColor(HexColor('#202024'))
    pdf.setFont('Helvetica-Bold', 26)
    pdf.drawString(48, 774, 'VikingBar sample invoice')
    pdf.setFillColor(HexColor('#b3211b'))
    pdf.setFont('Helvetica-Bold', 12)
    pdf.drawString(48, 740, 'DEMO ONLY - NOT A BILL OR PAYMENT REQUEST')
    pdf.setFillColor(HexColor('#303036'))
    pdf.setFont('Helvetica', 14)
    lines = [document, '7 August 2026' if paid else '7 September 2026',
             'Paid' if paid else 'Issued', 'Grouped invoice: both sample SIMs',
             '', 'Total: EUR 15.00', 'Amount due: EUR 0.00' if paid else 'Amount due: EUR 10.00',
             'Reduction: EUR 5.00', 'Viking Points used: 5']
    for index, line in enumerate(lines):
        pdf.drawString(48, 691 - index * 29, line)
    pdf.setStrokeColor(HexColor('#ccccd0'))
    pdf.line(48, 373, 547, 373)
    pdf.setFont('Helvetica', 11)
    pdf.drawString(48, 345, 'Synthetic document for the interactive VikingBar website demo.')
    pdf.drawString(48, 325, 'It contains no customer data or payment instructions.')
    pdf.showPage()
    pdf.save()
    print(target.name)
