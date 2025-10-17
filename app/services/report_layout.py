from reportlab.lib.units import inch
from reportlab.lib.utils import ImageReader
from datetime import datetime


def header(canvas, doc, logo_path=None, bank_name='BTrust Bank', max_w=1.8 * inch, max_h=0.9 * inch):
    """Draw header. Logo is drawn only on the first page if logo_path is provided.

    Signature is (canvas, doc, ...). When used with reportlab build hooks, wrap this
    function in a zero-arg wrapper or pass it via a lambda that binds logo_path.
    """
    canvas.saveState()

    logo_mid_offset = 6  # default offset to vertically align bank name
    if canvas.getPageNumber() == 1 and logo_path:
        try:
            img = ImageReader(logo_path)
            iw, ih = img.getSize()
            scale = min(max_w / iw, max_h / ih, 1.0)
            draw_w = iw * scale
            draw_h = ih * scale
            x = doc.leftMargin
            y = doc.pagesize[1] - doc.topMargin - draw_h
            canvas.drawImage(img, x, y, width=draw_w, height=draw_h, preserveAspectRatio=True, mask='auto')
            logo_mid_offset = draw_h / 2
        except Exception:
            # fail silently and use default offset
            logo_mid_offset = 6

    # Bank name at top-right (appears on every page)
    canvas.setFont('Helvetica-Bold', 14)
    text_x = doc.pagesize[0] - doc.rightMargin
    text_y = doc.pagesize[1] - doc.topMargin - logo_mid_offset
    canvas.drawRightString(text_x, text_y, bank_name)

    # Generated timestamp below the bank name (right-aligned)
    try:
        canvas.setFont('Helvetica', 10)
        generated_date = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        canvas.drawRightString(text_x, text_y - 18, f"Generated on: {generated_date}")
    except Exception:
        pass

    canvas.restoreState()


def footer(canvas, doc, left_text="Smart Banking, Built on Trust."):
    """Draw footer on every page with left text and right page number."""
    canvas.saveState()
    canvas.setFont('Helvetica', 9)
    footer_y = 0.5 * inch
    canvas.drawString(doc.leftMargin, footer_y, left_text)
    page_text = f"Page {canvas.getPageNumber()}"
    canvas.drawRightString(doc.pagesize[0] - doc.rightMargin, footer_y, page_text)
    canvas.restoreState()
