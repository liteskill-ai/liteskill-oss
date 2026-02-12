# Installing Webfonts
Follow these simple Steps.

## 1.
Put `nunito/` Folder into a Folder called `fonts/`.

## 2.
Put `nunito.css` into your `css/` Folder.

## 3. (Optional)
You may adapt the `url('path')` in `nunito.css` depends on your Website Filesystem.

## 4.
Import `nunito.css` at the top of you main Stylesheet.

```
@import url('nunito.css');
```

## 5.
You are now ready to use the following Rules in your CSS to specify each Font Style:
```
font-family: Nunito-ExtraLight;
font-family: Nunito-ExtraLightItalic;
font-family: Nunito-Light;
font-family: Nunito-LightItalic;
font-family: Nunito-Regular;
font-family: Nunito-Italic;
font-family: Nunito-Medium;
font-family: Nunito-MediumItalic;
font-family: Nunito-SemiBold;
font-family: Nunito-SemiBoldItalic;
font-family: Nunito-Bold;
font-family: Nunito-BoldItalic;
font-family: Nunito-ExtraBold;
font-family: Nunito-ExtraBoldItalic;
font-family: Nunito-Black;
font-family: Nunito-BlackItalic;
font-family: Nunito-Variable;
font-family: Nunito-VariableItalic;

```
## 6. (Optional)
Use `font-variation-settings` rule to controll axes of variable fonts:
ital 0.0wght 200.0

Available axes:
'ital' (range from 0.0 to 1.0'wght' (range from 200.0 to 1.0e3

