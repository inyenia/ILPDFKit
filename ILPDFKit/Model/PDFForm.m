// PDFForm.m
//
// Copyright (c) 2015 Iwe Labs
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "PDF.h"
#import "PDFFormButtonField.h"
#import "PDFFormTextField.h"
#import "PDFFormChoiceField.h"
#import "PDFFormSignatureField.h"
#import "PDFFormContainer.h"
#import <CoreText/CoreText.h>

@interface PDFForm(Delegates) <PDFWidgetAnnotationViewDelegate>
@end

@interface PDFForm(Private)
- (NSString *)getExportValueFrom:(PDFDictionary *)leaf;
- (NSString *)getSetAppearanceStreamFromLeaf:(PDFDictionary *)leaf;
- (void)updateFlagsString;
@end

@implementation PDFForm {
    NSUInteger _flags;
    NSUInteger _annotFlags;
    PDFWidgetAnnotationView *_formUIElement;
}

#pragma mark - NSObject

- (void)dealloc {
    [self removeObservers];
}

#pragma mark - PDFForm
#pragma mark - Initialization

- (instancetype)initWithFieldDictionary:(PDFDictionary *)leaf page:(PDFPage *)pg parent:(PDFFormContainer *)p {
    self = [super init];
    if (self != nil) {
        _dictionary = leaf;
        id value = [leaf inheritableValueForKey:@"V"];
		_value = [value isKindOfClass:PDFString.class] ? [value textString]:value;
		if (_value.length == 0) {
			CGPDFDictionaryRef aDict = leaf.dict;
			CGPDFStringRef objectString;
			if(CGPDFDictionaryGetString(aDict, "V", &objectString)) {
				NSString *tempStr = (NSString *)CFBridgingRelease(CGPDFStringCopyTextString(objectString));
				NSLog(@"V %@", tempStr);
				_value = tempStr;
			}
		}
        id defaultValue = [leaf inheritableValueForKey:@"DV"];
        _defaultValue = ([defaultValue isKindOfClass:PDFString.class]) ? [defaultValue textString]:defaultValue;
        NSMutableArray *nameComponents = [NSMutableArray array];
        for (PDFString *obj in [[leaf parentValuesForKey:@"T"] reverseObjectEnumerator]) [nameComponents addObject:[obj textString]];
        _name = [nameComponents componentsJoinedByString:@"."];
        NSString *formTypeString = [leaf inheritableValueForKey:@"FT"];
        _uname = [[leaf inheritableValueForKey:@"TU"] textString];
        _flags = [[leaf inheritableValueForKey:@"Ff"] unsignedIntegerValue];
        NSNumber *formTextAlignment = [leaf  inheritableValueForKey:@"Q"];
        _exportValue = [self getExportValueFrom:leaf];
        _setAppearanceStream = [self getSetAppearanceStreamFromLeaf:leaf];
        PDFArray *arr = [leaf inheritableValueForKey:@"Opt"];
        NSMutableArray *temp = [NSMutableArray array];
        for (id obj in arr) {
            if ([obj isKindOfClass:[PDFArray class]]) {
                [temp addObject:[obj[0] textString] ?: @""];
            } else {
                [temp addObject:[obj textString] ?: @""];
            }
        }
        self.options = [NSArray arrayWithArray:temp];
		
		_textFont = [self fontFromDictionary:leaf];
		_textColor = [self textColorFromDictionary:leaf];

        if ([formTypeString isEqualToString:@"Btn"]) {
            _formType = PDFFormTypeButton;
        } else if([formTypeString isEqualToString:@"Tx"]) {
            _formType = PDFFormTypeText;
        } else if([formTypeString isEqualToString:@"Ch"]) {
            _formType = PDFFormTypeChoice;
        } else if([formTypeString isEqualToString:@"Sig"]) {
            _formType = PDFFormTypeSignature;
        }

        NSMutableArray *tempRect = [NSMutableArray array];
        for (NSNumber *num in leaf[@"Rect"]) [tempRect addObject:num];
        _rawRect = [NSArray arrayWithArray:tempRect];
        _frame = [[(PDFArray *)(leaf[@"Rect"]) rect] CGRectValue];
        _page = pg.pageNumber;
        _mediaBox = pg.mediaBox;
        _cropBox =  pg.cropBox;
        if (leaf[@"F"]) {
            _annotFlags = [leaf[@"F"] unsignedIntegerValue];
        }
        if (formTextAlignment) {
            _textAlignment = [formTextAlignment unsignedIntegerValue];
        }
        [self updateFlagsString];
        _parent = p;
        {
            BOOL noRotate = (_annotFlags & PDFAnnotationFlagNoRotate) > 0;
            NSUInteger rotation = [(PDFPage *)(self.parent.document.pages[_page-1]) rotationAngle];
            if (noRotate)rotation = 0;
            CGFloat a = self.frame.size.width;
            CGFloat b = self.frame.size.height;
            CGFloat fx = self.frame.origin.x;
            CGFloat fy = self.frame.origin.y;
            CGFloat tw = self.cropBox.size.width;
            CGFloat th = self.cropBox.size.height;

            switch(rotation%360) {
                case 0:
                    break;
                case 90:
                    _frame = CGRectMake(fy,th-fx-a, b, a);
                    break;
                case 180:
                    _frame = CGRectMake(tw-fx-a, th-fy-b, a, b);
                    break;
                case 270:
                    _frame = CGRectMake(tw-fy-b,fx, b, a);
                default:
                    break;
            }
        }
    }

    return self;
}

#pragma mark - Getters/Setters

- (void)setOptions:(NSArray *)opt {
    if ([opt isKindOfClass:[NSNull class]]) {
        self.options = nil;
        return;
    }
    _options = nil;
    _options = opt;
}

- (void)setValue:(NSString *)val {
    if ([val isKindOfClass:[NSNull class]]) {
        [self setValue:nil];
        return;
    }
    if (![val isEqualToString:_value] && (val||_value)) {
        _modified = YES;
    }
    if (_value != val) {
        _value = nil;;
        _value = val;
    }
}


#pragma mark - Flags


- (void)updateFlagsString {
    NSString *temp = @"";

    if ((_flags & PDFFormFlagReadOnly) > 0) {
        temp = [temp stringByAppendingString:@"-ReadOnly"];
    }
    if ((_flags & PDFFormFlagRequired) > 0) {
        temp = [temp stringByAppendingString:@"-Required"];
    }
    if ((_flags & PDFFormFlagNoExport) > 0) {
        temp = [temp stringByAppendingString:@"-NoExport"];
    }
    if (_formType == PDFFormTypeButton) {

        if ((_flags & PDFFormFlagButtonNoToggleToOff) > 0) {
            temp = [temp stringByAppendingString:@"-NoToggleToOff"];
        }
        if ((_flags & PDFFormFlagButtonRadio) > 0) {
            temp = [temp stringByAppendingString:@"-Radio"];
        }
        if ((_flags & PDFFormFlagButtonPushButton) > 0) {
            temp = [temp stringByAppendingString:@"-Pushbutton"];
        }
    } else if (_formType == PDFFormTypeChoice) {
        if ((_flags & PDFFormFlagChoiceFieldIsCombo) > 0) {
            temp = [temp stringByAppendingString:@"-Combo"];
        }
        if ((_flags & PDFFormFlagChoiceFieldEditable) > 0) {
            temp = [temp stringByAppendingString:@"-Edit"];
        }
        if ((_flags & PDFFormFlagChoiceFieldSorted) > 0) {
            temp = [temp stringByAppendingString:@"-Sort"];
        }
    } else if(_formType == PDFFormTypeText) {
        if ((_flags & PDFFormFlagTextFieldMultiline) > 0) {
            temp = [temp stringByAppendingString:@"-Multiline"];
        } if((_flags & PDFFormFlagTextFieldPassword) > 0) {
            temp = [temp stringByAppendingString:@"-Password"];
        }
    }

    if ((_annotFlags & PDFAnnotationFlagInvisible) > 0) {
        temp = [temp stringByAppendingString:@"-Invisible"];
    }
    if ((_annotFlags & PDFAnnotationFlagHidden) > 0) {
        temp = [temp stringByAppendingString:@"-Hidden"];
    }
    if ((_annotFlags & PDFAnnotationFlagPrint) > 0) {
        temp = [temp stringByAppendingString:@"-Print"];
    }
    if ((_annotFlags & PDFAnnotationFlagNoZoom) > 0) {
        temp = [temp stringByAppendingString:@"-NoZoom"];
    }
    if ((_annotFlags & PDFAnnotationFlagNoRotate) > 0) {
        temp = [temp stringByAppendingString:@"-NoRotate"];
    }
    if ((_annotFlags & PDFAnnotationFlagNoView) > 0) {
        temp = [temp stringByAppendingString:@"-NoView"];
    }
    _flagsString = temp;
}


#pragma mark - Resetting Forms

- (void)reset {
    self.value = self.defaultValue;
}

#pragma mark - Rendering

- (void)vectorRenderInPDFContext:(CGContextRef)ctx forRect:(CGRect)rect font:(UIFont *)font
{
	if (self.formType == PDFFormTypeText || self.formType == PDFFormTypeChoice){
		NSString *text = self.value;
		UIGraphicsPushContext(ctx);
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle defaultParagraphStyle] mutableCopy];
        paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
        paragraphStyle.alignment = self.textAlignment;
		if (_textFont && _textFont.pointSize > 0) {
			font = _textFont;
		} else if (!font) {
			font = [UIFont systemFontOfSize:[PDFWidgetAnnotationView fontSizeForRect:rect value:self.value multiline:((_flags & PDFFormFlagTextFieldMultiline) > 0 && self.formType == PDFFormTypeText) choice:self.formType == PDFFormTypeChoice]];
		}
		NSString *fontName = font.fontName;
		CGFloat fontSize = font.pointSize;
		[text drawInRect:CGRectMake(0, 0, rect.size.width, rect.size.height*2.0) withAttributes:@{NSFontAttributeName:font,NSParagraphStyleAttributeName: paragraphStyle, NSForegroundColorAttributeName:_textColor}];
		UIGraphicsPopContext();
    } else if (self.formType == PDFFormTypeButton) {
        [PDFFormButtonField drawWithRect:rect context:ctx back:NO selected:[self.value isEqualToString:self.exportValue] && (_flags & PDFFormFlagButtonPushButton) == 0 radio:(_flags & PDFFormFlagButtonRadio) > 0];
    }
}

- (PDFWidgetAnnotationView *)createWidgetAnnotationViewForSuperviewWithWidth:(CGFloat)viewWidth xMargin:(CGFloat)xmargin yMargin:(CGFloat)ymargin {
    if ((_annotFlags & PDFAnnotationFlagHidden) > 0) return nil;
    if ((_annotFlags & PDFAnnotationFlagInvisible) > 0) return nil;
    if ((_annotFlags & PDFAnnotationFlagNoView) > 0) return nil;
    CGFloat width = _cropBox.size.width;
    CGFloat maxPageWidth = width;
    for (PDFPage *pg in self.parent.document.pages) {
        if([pg cropBox].size.width > maxPageWidth) maxPageWidth = [pg cropBox].size.width;
    }
    /*
     vwidth-2*xmargin = pixel width of canvas on screen for full screen scaled page
     xmargin = pixel width of grey border between canvas and edge of UIWebView for full scaled page.
     maxWidth = PDF canvas points of widest page;
     ((vwidth-2*xmargin)/maxWidth) = converstion factor from canvas space to device space.
     Thus hmargin is the horizonal pixel margin from the border of the screen to the beginning of the page canvas.
     */
    CGFloat hmargin = ((maxPageWidth-width)/2)*((viewWidth-(2*xmargin))/maxPageWidth)+xmargin;
    CGFloat height = _cropBox.size.height;

    //correctedFrame applies to the widgit, not the full PDF window
    CGRect correctedFrame = CGRectMake(_frame.origin.x-_cropBox.origin.x, height-_frame.origin.y-_frame.size.height-_cropBox.origin.y, _frame.size.width, _frame.size.height);

    CGFloat realWidth = viewWidth - (2*hmargin);
    CGFloat factor = realWidth/width;
    CGFloat pageOffset = 0;

    for (NSUInteger c = 0; c < self.page-1; c++) {
        PDFPage *pg = self.parent.document.pages[c];
        CGFloat iwidth = [pg cropBox].size.width;
        CGFloat ihmargin = ((maxPageWidth-iwidth)/2)*((viewWidth- (2 * xmargin))/maxPageWidth)+xmargin;
        CGFloat iheight = [pg cropBox].size.height;
        CGFloat irealWidth = viewWidth- (2 * ihmargin);
        CGFloat ifactor = irealWidth/iwidth;

        pageOffset+= (iheight * ifactor) + ymargin;
        //DPNote: ymargin is just a constant in the PDFViewController.getMargins.  They are hard coded margins.  I have now hardcoded margins for different devices so they end up in the right place.
    }

    _pageFrame =  CGRectIntegral(CGRectMake(correctedFrame.origin.x*factor+hmargin, correctedFrame.origin.y*factor+ymargin, correctedFrame.size.width*factor, correctedFrame.size.height*factor));

    if (_formUIElement) {
        _formUIElement = nil;
    }

    //A full rendered PDF is really a single "window" or "view".  So we have to manually add offsets and
    // build each UI element as if it was in a single window.
    // _pageFrame represents the frame/rectangle for the current widget
    // _uiBaseFrame represents where a widgit should be located in this larger window.
    // pageOffset represents what needs to be added on the Y axis for this pages origins to be placed properly

    _uiBaseFrame = CGRectIntegral(CGRectMake(_pageFrame.origin.x, _pageFrame.origin.y+pageOffset, _pageFrame.size.width, _pageFrame.size.height));

    switch (_formType) {
        case PDFFormTypeText:
            _formUIElement = [[PDFFormTextField alloc] initWithFrame:_uiBaseFrame multiline:((_flags & PDFFormFlagTextFieldMultiline) > 0) alignment:_textAlignment secureEntry:((_flags & PDFFormFlagTextFieldPassword) > 0) readOnly:((_flags & PDFFormFlagReadOnly) > 0)];
        break;
        case PDFFormTypeButton: {
            BOOL radio = ((_flags & PDFFormFlagButtonRadio) > 0);
            if (_setAppearanceStream) {
                if ([_setAppearanceStream rangeOfString:@"ZaDb"].location != NSNotFound && [_setAppearanceStream rangeOfString:@"(l)"].location!=NSNotFound)radio = YES;
            }
            PDFFormButtonField *temp = [[PDFFormButtonField alloc] initWithFrame:_uiBaseFrame radio:radio];
            temp.noOff = ((_flags & PDFFormFlagButtonNoToggleToOff) > 0);
            temp.name = self.name;
            temp.pushButton = ((_flags & PDFFormFlagButtonPushButton) > 0);
            temp.exportValue = self.exportValue;
            _formUIElement = temp;
        }
        break;
        case PDFFormTypeChoice:
            _formUIElement = [[PDFFormChoiceField alloc] initWithFrame:_uiBaseFrame options:_options];
        break;
        case PDFFormTypeSignature:
            _formUIElement = [[PDFFormSignatureField alloc] initWithFrame:_uiBaseFrame];
        break;
        case PDFFormTypeNone:
        default:
            break;
    }

    if (_formUIElement) {
        [_formUIElement setValue:self.value];
        _formUIElement.delegate = self;
        [self addObserver:_formUIElement forKeyPath:@"value" options:NSKeyValueObservingOptionNew context:NULL];
        [self addObserver:_formUIElement forKeyPath:@"options" options:NSKeyValueObservingOptionNew context:NULL];
    }
      return _formUIElement;

}

#pragma mark - PDF fonts

- (UIFont*) fontFromDictionary:(PDFDictionary*)leaf  {
	UIFont *result = nil;
	// DA : Default Appearance
	NSMutableArray *daComponents = [NSMutableArray array];
	for (PDFString *obj in [[leaf parentValuesForKey:@"DA"] reverseObjectEnumerator]) {
		[daComponents addObject:[obj textString]];
	}
	NSString *daInfo = daComponents.count > 0 ? [daComponents firstObject] : nil; // ej: /Helv 12 Tf 0.25 0.25 0.25 rg
	NSArray *comps = daInfo ? [daInfo componentsSeparatedByString:@"Tf"] : nil;
	NSArray *daValues = comps && comps.count > 0 ? [[comps firstObject] componentsSeparatedByString:@" "] : nil;
	if (daValues.count >= 3) {
		NSString *daInfo = [daComponents firstObject];
		daInfo = [daInfo substringFromIndex:1];
		NSArray *daValues = [daInfo componentsSeparatedByString:@" "];
		NSString *fontKey = [daValues objectAtIndex:0];
		NSString *fontSize = [daValues objectAtIndex:1];
		result = [self fontWithAcroFieldKey:fontKey andSize:fontSize];
	}
	return result;
}

- (UIColor*) textColorFromDictionary:(PDFDictionary*)leaf {
	UIColor *result = nil;
	
	// DA : Default Appearance
	NSMutableArray *daComponents = [NSMutableArray array];
	for (PDFString *obj in [[leaf parentValuesForKey:@"DA"] reverseObjectEnumerator]) {
		[daComponents addObject:[obj textString]];
	}
	NSString *daInfo = daComponents.count > 0 ? [daComponents firstObject] : nil; // ej: /Helv 12 Tf 0.25 0.25 0.25 rg
	
	NSArray *daValues = daInfo ? [daInfo componentsSeparatedByString:@" "] : nil;
	if ([daInfo containsString:@"rg"] && [daInfo containsString:@"Tf"] && daValues.count == 7) {
		NSString *red = [daValues objectAtIndex:3];
		NSString *green = [daValues objectAtIndex:4];
		NSString *blue = [daValues objectAtIndex:5];
		result = [UIColor colorWithRed:[red floatValue] green:[green floatValue] blue:[blue floatValue] alpha:1.0];
	} else {
		result = [UIColor blackColor];
	}
	return result;
}

#pragma mark - PDFWidgetAnnotationViewDelegate

- (void)widgetAnnotationEntered:(PDFWidgetAnnotationView *)sender {
}

- (void)widgetAnnotationValueChanged:(PDFWidgetAnnotationView *)sender {
    _modified = YES;
    PDFWidgetAnnotationView *v = ((PDFWidgetAnnotationView *)sender);
    if ([v isKindOfClass:[PDFFormButtonField class]]) {
        PDFFormButtonField *button =  (PDFFormButtonField *)v;
        BOOL set = [button.exportValue isEqualToString:button.value];
        if (!button.pushButton) {
            if (button.noOff && set) {
                return;
            } else {
                [_parent setValue:(set ? nil:_exportValue) forFormWithName:self.name];
            }
        } else {
            _modified = NO;
            return;
        }
    } else {
        [_parent setValue:[v value] forFormWithName:self.name];
    }
}

- (void)widgetAnnotationOptionsChanged:(PDFWidgetAnnotationView *)sender {
    self.options = ((PDFWidgetAnnotationView *)sender).options;
}

#pragma mark - Private

- (NSString *)getSetAppearanceStreamFromLeaf:(PDFDictionary *)leaf {
    PDFDictionary *ap = nil;
    if ((ap = leaf[@"AP"])) {
        PDFDictionary *n = nil;
        if ([(n = ap[@"N"]) isKindOfClass:[PDFDictionary class]]) {
            for (PDFName *key in [n allKeys]) {
                if (![key isEqualToString:@"Off"] && ![key isEqualToString:@"OFF"]) {
                    PDFStream *str = n[key];
                    if ([str isKindOfClass:[PDFStream class]]) {
                        NSData *dat = str.data;
                        if (str.dataFormat == CGPDFDataFormatRaw) {
                            return [PDFUtility stringFromPDFData:dat];
                        }
                    }
                }
            }
        }
    }
    return nil;
}

- (NSString *)getExportValueFrom:(PDFDictionary *)leaf {
    PDFDictionary *ap = nil;
    if ((ap = leaf[@"AP"])) {
        PDFDictionary *n = nil;
        if ([(n = ap[@"N"]) isKindOfClass:[PDFDictionary class]]) {
            for (PDFName *key in [n allKeys]) {
                if(![key isEqualToString:@"Off"] && ![key isEqualToString:@"OFF"])return key;
            }
        }
    }
    id as = nil;
    if ((as = leaf[@"AS"])) {
        if ([as isKindOfClass:NSString.class]) as = [as textString];
        return as;
    }
    return nil;
}


#pragma mark - KVO

- (void)removeObservers {
    if (_formUIElement) {
        [self removeObserver:_formUIElement forKeyPath:@"value"];
        [self removeObserver:_formUIElement forKeyPath:@"options"];
        _formUIElement = nil;
    }
}

#pragma mark - Font names for AcroFields (AroFields.java), [UIFont familyNames] and [UIFont fontNamesForFamilyName]

- (NSDictionary*) dictionaryWithAcroFieldFonts {
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	[dictionary setObject:@"Courier-BoldOblique" forKey:@"CoBO"];
	[dictionary setObject:@"Courier-Bold" forKey:@"CoBo"];
	[dictionary setObject:@"Courier-Oblique" forKey:@"CoOb"];
	[dictionary setObject:@"Courier" forKey:@"Cour"];
	[dictionary setObject:@"Helvetica-BoldOblique" forKey:@"HeBO"];
	[dictionary setObject:@"Helvetica-Bold" forKey:@"HeBo"];
	[dictionary setObject:@"Helvetica-Oblique" forKey:@"HeOb"];
	[dictionary setObject:@"Helvetica" forKey:@"Helv"];
	[dictionary setObject:@"Symbol" forKey:@"Symb"];
	[dictionary setObject:@"TimesNewRomanPS-BoldItalicMT" forKey:@"TiBI"];
	[dictionary setObject:@"TimesNewRomanPS-BoldMT" forKey:@"TiBo"];
	[dictionary setObject:@"TimesNewRomanPS-BoldMT" forKey:@"TiIt"];
	[dictionary setObject:@"TimesNewRomanPSMT" forKey:@"TiRo"];
	return dictionary;
}

- (UIFont*) fontWithAcroFieldKey:(NSString*)key andSize:(NSString*)size {
	UIFont *result = nil;
	CGFloat fontSize = [size floatValue];
	NSDictionary* dictionaryFonts = [self dictionaryWithAcroFieldFonts];
	if (!result) {
		// Custom fonts (previosly attached to the project)
		result = [UIFont fontWithName:key size:fontSize];
	}
	if ([[dictionaryFonts allKeys] containsObject:key]) {
		// Fonts recognized by AcroField standard
		result = [UIFont fontWithName:[dictionaryFonts objectForKey:key] size:fontSize];
	}
	if (!result) {
		// Fonts recognized by iOS
		NSArray *nameStyle = [key componentsSeparatedByString:@","];
		if (nameStyle.count == 2) {
			NSString *fontFamily = [nameStyle firstObject];
			NSString *fontStyle = [nameStyle lastObject];
			for (NSString* styles in [UIFont fontNamesForFamilyName:fontFamily]) {
				if ([styles containsString:fontStyle]) {
					result = [UIFont fontWithName:styles size:fontSize];
					break;
				}
			}
		}
	}
	if (!result) {
		// Fonts not recognized.
		result = [UIFont systemFontOfSize:fontSize];
	}
	return result;
}

@end
