import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

public enum CaptureAnnotationRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    public static func render(
        image: CGImage,
        selection: CGRect,
        annotations: [CaptureAnnotationItem],
        scale: CGFloat
    ) -> CGImage? {
        let overlaySize = CGSize(
            width: scale > 0 ? CGFloat(image.width) / scale : CGFloat(image.width),
            height: scale > 0 ? CGFloat(image.height) / scale : CGFloat(image.height)
        )
        return render(
            image: image,
            selection: selection,
            annotations: annotations,
            overlaySize: overlaySize
        )
    }

    /// Crops using the source image's actual pixel size against the overlay point bounds.
    public static func render(
        image: CGImage,
        selection: CGRect,
        annotations: [CaptureAnnotationItem],
        overlaySize: CGSize
    ) -> CGImage? {
        let scaleX = overlaySize.width > 0 ? CGFloat(image.width) / overlaySize.width : 1
        let scaleY = overlaySize.height > 0 ? CGFloat(image.height) / overlaySize.height : 1
        let pixelSelection = CGRect(
            x: selection.minX * scaleX,
            y: selection.minY * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral
        guard pixelSelection.width > 0,
              pixelSelection.height > 0,
              let cropped = image.cropping(to: clamped(pixelSelection, to: image)) else {
            return nil
        }

        let width = cropped.width
        let height = cropped.height
        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cropped
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        for annotation in annotations {
            draw(
                annotation,
                in: context,
                selection: selection,
                scaleX: scaleX,
                scaleY: scaleY,
                imageHeight: CGFloat(height)
            )
        }
        return context.makeImage()
    }

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    /// Live overlay helper: blur a source image region and return a CGImage plus point draw rect.
    public static func blurredRegion(
        of image: CGImage,
        rect: CGRect,
        radius: CGFloat,
        overlaySize: CGSize
    ) -> (cgImage: CGImage, drawRect: CGRect)? {
        let scaleX = overlaySize.width > 0 ? CGFloat(image.width) / overlaySize.width : 1
        let scaleY = overlaySize.height > 0 ? CGFloat(image.height) / overlaySize.height : 1
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: max(2, rect.width * scaleX),
            height: max(2, rect.height * scaleY)
        ).integral
        let clampedRect = clamped(pixelRect, to: image)
        guard clampedRect.width > 1, clampedRect.height > 1,
              let cropped = image.cropping(to: clampedRect) else {
            return nil
        }
        let blurRadius = max(1, radius * ((scaleX + scaleY) * 0.5))
        guard let blurred = gaussianBlur(cropped, radius: blurRadius) else {
            return nil
        }
        let drawRect = CGRect(
            x: clampedRect.origin.x / scaleX,
            y: clampedRect.origin.y / scaleY,
            width: clampedRect.width / scaleX,
            height: clampedRect.height / scaleY
        )
        return (blurred, drawRect)
    }

    private static func clamped(_ rect: CGRect, to image: CGImage) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return rect.intersection(bounds)
    }

    private static func draw(
        _ annotation: CaptureAnnotationItem,
        in context: CGContext,
        selection: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        imageHeight: CGFloat
    ) {
        let start = pixelPoint(annotation.start, selection: selection, scaleX: scaleX, scaleY: scaleY, imageHeight: imageHeight)
        let end = pixelPoint(annotation.end, selection: selection, scaleX: scaleX, scaleY: scaleY, imageHeight: imageHeight)
        let color = CGColor(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue,
            alpha: annotation.color.alpha
        )
        let averageScale = (scaleX + scaleY) * 0.5
        let lineWidth = max(1, annotation.lineWidth * averageScale)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .select:
            break
        case .arrow:
            drawArrow(from: start, to: end, in: context, lineWidth: lineWidth)
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            context.stroke(rect)
        case .ellipse:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            context.strokeEllipse(in: rect)
        case .mosaic:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(4, abs(end.x - start.x)),
                height: max(4, abs(end.y - start.y))
            )
            applyGaussianMosaic(in: context, rect: rect, radius: max(1, annotation.blurRadius * averageScale))
        case .sequence:
            let radius = max(10, annotation.lineWidth * 4 * averageScale)
            let center = end
            context.fillEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            drawCenteredText(
                "\(max(1, annotation.sequenceNumber))",
                at: center,
                in: context,
                color: CGColor(gray: 1, alpha: 1),
                fontSize: max(11, annotation.fontSize * averageScale * 0.75)
            )
        case .text:
            drawCenteredText(
                annotation.text.isEmpty ? "Text" : annotation.text,
                at: end,
                in: context,
                color: color,
                fontSize: max(12, annotation.fontSize * averageScale),
                centered: false
            )
        }
    }

    private static func pixelPoint(
        _ point: CGPoint,
        selection: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        imageHeight: CGFloat
    ) -> CGPoint {
        let local = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
        // Flipped view points and CGImage share a top-left origin; convert into
        // the bottom-left CGBitmap context used for the cropped output.
        return CGPoint(x: local.x * scaleX, y: imageHeight - local.y * scaleY)
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: CGContext,
        lineWidth: CGFloat
    ) {
        let geometry = arrowGeometry(from: start, to: end, lineWidth: lineWidth)

        // Stop the shaft at the head base so the stroke cannot poke through the tip.
        context.saveGState()
        context.setLineCap(.butt)
        context.beginPath()
        context.move(to: geometry.shaftStart)
        context.addLine(to: geometry.shaftEnd)
        context.strokePath()
        context.restoreGState()

        context.beginPath()
        context.move(to: geometry.tip)
        context.addLine(to: geometry.left)
        context.addLine(to: geometry.right)
        context.closePath()
        context.fillPath()
    }

    /// Shared arrow layout: shaft ends at the triangular head base, not the tip.
    public static func arrowGeometry(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat
    ) -> (shaftStart: CGPoint, shaftEnd: CGPoint, tip: CGPoint, left: CGPoint, right: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)
        let head = min(max(10, lineWidth * 4), max(length * 0.45, lineWidth * 2))
        let left = CGPoint(
            x: end.x - head * cos(angle - .pi / 6),
            y: end.y - head * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: end.x - head * cos(angle + .pi / 6),
            y: end.y - head * sin(angle + .pi / 6)
        )
        // Midpoint of the head base along the shaft direction.
        let baseInset = head * cos(.pi / 6)
        let shaftEnd = CGPoint(
            x: end.x - baseInset * cos(angle),
            y: end.y - baseInset * sin(angle)
        )
        return (start, shaftEnd, end, left, right)
    }

    private static func applyGaussianMosaic(in context: CGContext, rect: CGRect, radius: CGFloat) {
        guard let image = context.makeImage() else { return }
        let integral = rect.integral
        // `rect` is in CGContext bottom-left space; CGImage cropping is top-left.
        let cropRect = CGRect(
            x: integral.origin.x,
            y: CGFloat(image.height) - integral.maxY,
            width: integral.width,
            height: integral.height
        )
        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = image.cropping(to: clamped(cropRect, to: image)),
              let blurred = gaussianBlur(cropped, radius: radius) else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(blurred, in: integral)
        context.restoreGState()
    }

    private static func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: Double(radius)), forKey: kCIInputRadiusKey)
        let extent = CIImage(cgImage: image).extent
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent)
    }

    private static func drawCenteredText(
        _ string: String,
        at point: CGPoint,
        in context: CGContext,
        color: CGColor,
        fontSize: CGFloat,
        centered: Bool = true
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            string as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.saveGState()
        context.textMatrix = .identity
        let x = centered ? point.x - bounds.width / 2 : point.x
        let y = centered ? point.y - bounds.height / 2 : point.y - bounds.height
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
