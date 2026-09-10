import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

class AppTheme {
  /// 私有构造，禁止实例化。
  const AppTheme._();

  /// 浅色主题。
  static final ThemeData light = _build(AppInk.light);

  /// 深色主题。
  static final ThemeData dark = _build(AppInk.darkMode);

  /// 由语义色板构建完整主题。
  static ThemeData _build(AppInk ink) {
    final bool isDark = ink.dark;
    final ColorScheme scheme = ColorScheme(
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: ink.primary,
      onPrimary: ink.onPrimary,
      primaryContainer: ink.primary.withValues(alpha: isDark ? 0.24 : 0.12),
      onPrimaryContainer: ink.primary,
      secondary: ink.accent,
      onSecondary: ink.paper,
      error: ink.danger,
      onError: ink.paper,
      surface: ink.surface,
      onSurface: ink.ink,
      onSurfaceVariant: ink.inkSoft,
      outline: ink.border,
      outlineVariant: ink.divider,
      surfaceContainerLowest: ink.surfaceRaised,
      surfaceContainerLow: ink.surface,
      surfaceContainer: ink.surface,
      surfaceContainerHigh: ink.surfaceRaised,
      surfaceContainerHighest: ink.surfaceRaised,
      scrim: Colors.black.withValues(alpha: 0.32),
    );

    final TextTheme text = _textTheme(ink);

    return ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: ink.paper,
      canvasColor: ink.paper,
      splashColor: ink.ink.withValues(alpha: 0.045),
      highlightColor: Colors.transparent,
      hoverColor: ink.hoverTint,
      focusColor: ink.selectTint,
      dividerColor: ink.divider,
      textTheme: text,
      primaryTextTheme: text,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      appBarTheme: AppBarThemeData(
        backgroundColor: ink.surface,
        foregroundColor: ink.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        shadowColor: Colors.transparent,
        centerTitle: false,
        titleSpacing: AppTokens.s4,
        toolbarHeight: 56,
        iconTheme: IconThemeData(color: ink.inkSoft, size: 20),
        actionsIconTheme: IconThemeData(color: ink.inkSoft, size: 20),
        titleTextStyle: AppFonts.text(
          ink.ink,
          size: 17,
          weight: FontWeight.w600,
          height: 1.3,
        ),
        shape: Border(
          bottom: BorderSide(color: ink.divider, width: AppTokens.hairline),
        ),
      ),
      cardTheme: CardThemeData(
        color: ink.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.radiusCard,
          side: BorderSide(color: ink.border, width: AppTokens.cardBorder),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ink.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        alignment: Alignment.center,
        insetPadding: const EdgeInsets.all(AppTokens.s8),
        titleTextStyle: AppFonts.text(
            ink.ink, size: 17.5, weight: FontWeight.w600, height: 1.4),
        contentTextStyle: AppFonts.text(ink.inkSoft, size: 14, height: 1.65),
        iconColor: ink.primary,
        actionsPadding: const EdgeInsets.fromLTRB(
            AppTokens.s3, 0, AppTokens.s4, AppTokens.s4),
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.radiusDialog,
          side: BorderSide(color: ink.border, width: AppTokens.cardBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: ink.surfaceRaised,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s3, vertical: 11),
        hintStyle: AppFonts.text(ink.inkFaint, size: 14, height: 1.4),
        labelStyle: AppFonts.text(ink.inkSoft, size: 13, height: 1.4),
        floatingLabelStyle: AppFonts.text(
          ink.primary,
          size: 12.5,
          weight: FontWeight.w600,
        ),
        helperStyle: AppFonts.text(ink.inkFaint, size: 12, height: 1.4),
        errorStyle: AppFonts.text(ink.danger, size: 12, height: 1.4),
        counterStyle: AppFonts.text(ink.inkFaint, size: 12),
        prefixIconColor: ink.inkFaint,
        suffixIconColor: ink.inkFaint,
        border: _fieldBorder(ink.border),
        enabledBorder: _fieldBorder(ink.border),
        focusedBorder: _fieldBorder(ink.primary, width: 1.6),
        hoverColor: ink.hoverTint,
        errorBorder: _fieldBorder(ink.danger),
        focusedErrorBorder: _fieldBorder(ink.danger, width: 1.6),
        disabledBorder: _fieldBorder(ink.divider),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(ink.primary),
          foregroundColor: WidgetStatePropertyAll<Color>(ink.onPrimary),
          shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          elevation: const WidgetStatePropertyAll<double>(0),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: AppTokens.s4)),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
          maximumSize:
              const WidgetStatePropertyAll<Size>(Size(double.infinity, 48)),
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            AppFonts.text(ink.onPrimary, size: 14, weight: FontWeight.w600, height: 1.2),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2)))),
          overlayColor: WidgetStatePropertyAll<Color>(
              Colors.white.withValues(alpha: isDark ? 0.14 : 0.16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll<Color>(ink.ink),
          backgroundColor: WidgetStatePropertyAll<Color>(
              ink.surface.withValues(alpha: 0.6)),
          side: WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: ink.border, width: AppTokens.cardBorder)),
          shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          elevation: const WidgetStatePropertyAll<double>(0),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: AppTokens.s4)),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            AppFonts.text(ink.ink, size: 14, weight: FontWeight.w500, height: 1.2),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2)))),
          overlayColor: WidgetStatePropertyAll<Color>(ink.hoverTint),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll<Color>(ink.primary),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: AppTokens.s3)),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 36)),
          shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          elevation: const WidgetStatePropertyAll<double>(0),
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            AppFonts.text(ink.primary, size: 14, weight: FontWeight.w500, height: 1.2),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2)))),
          overlayColor: WidgetStatePropertyAll<Color>(ink.selectTint),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll<Color>(ink.inkSoft),
          iconSize: const WidgetStatePropertyAll<double>(20),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(36, 36)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.all(AppTokens.s2)),
          visualDensity: VisualDensity.compact,
          shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          elevation: const WidgetStatePropertyAll<double>(0),
          overlayColor: WidgetStatePropertyAll<Color>(ink.hoverTint),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2)))),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: ink.inkSoft,
        textColor: ink.ink,
        selectedColor: ink.primary,
        selectedTileColor: ink.selectTint,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2))),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s3, vertical: 2),
        minLeadingWidth: AppTokens.s3,
        horizontalTitleGap: AppTokens.s3,
        titleTextStyle: AppFonts.text(ink.ink, size: 14.5, height: 1.4),
        subtitleTextStyle: AppFonts.text(ink.inkSoft, size: 12.5, height: 1.4),
        leadingAndTrailingTextStyle:
            AppFonts.text(ink.inkFaint, size: 12, height: 1.4),
        visualDensity: VisualDensity.compact,
        minTileHeight: 44,
      ),
      dividerTheme: DividerThemeData(
        color: ink.divider,
        thickness: AppTokens.hairline,
        space: AppTokens.hairline,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: ink.selectTint,
        secondarySelectedColor: ink.selectTint,
        disabledColor: ink.divider,
        checkmarkColor: ink.primary,
        deleteIconColor: ink.inkFaint,
        shadowColor: Colors.transparent,
        elevation: 0,
        pressElevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s2),
        labelPadding: const EdgeInsets.symmetric(horizontal: AppTokens.s1),
        labelStyle: AppFonts.text(ink.inkSoft, size: 12.5, height: 1.4),
        secondaryLabelStyle:
            AppFonts.text(ink.primary, size: 12.5, height: 1.4),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2))),
        side: BorderSide(color: ink.border, width: AppTokens.hairline),
        showCheckmark: false,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: ink.primary,
        unselectedLabelColor: ink.inkSoft,
        indicatorColor: ink.primary,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: AppFonts.text(ink.primary, size: 14, weight: FontWeight.w600),
        unselectedLabelStyle: AppFonts.text(ink.inkSoft, size: 14),
        overlayColor: WidgetStatePropertyAll<Color>(ink.hoverTint),
        tabAlignment: TabAlignment.start,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 60,
        backgroundColor: ink.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: ink.selectTint,
        shadowColor: Colors.transparent,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => AppFonts.text(
            states.contains(WidgetState.selected) ? ink.primary : ink.inkSoft,
            size: 12,
            weight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? ink.primary
                : ink.inkSoft,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? ink.primary
                : ink.inkSoft,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? ink.selectTint
                : Colors.transparent,
          ),
          side: WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: ink.border, width: AppTokens.cardBorder)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: AppTokens.s3)),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 36)),
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            AppFonts.text(ink.inkSoft, size: 13, weight: FontWeight.w500),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2)))),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: ink.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: ink.ink.withValues(alpha: 0.12),
        iconSize: 18,
        iconColor: ink.inkSoft,
        textStyle: AppFonts.text(ink.ink, size: 13.5, height: 1.5),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2))),
        menuPadding: const EdgeInsets.symmetric(vertical: AppTokens.s2),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: ink.primary,
        linearTrackColor: ink.divider,
        circularTrackColor: ink.divider,
        linearMinHeight: 5,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: ink.primary,
        inactiveTrackColor: ink.divider,
        thumbColor: ink.primary,
        overlayColor: ink.selectTint,
        trackHeight: 4,
        valueIndicatorColor: ink.ink,
        valueIndicatorTextStyle:
            AppFonts.text(ink.paper, size: 12, weight: FontWeight.w600),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? ink.onPrimary
              : (isDark ? ink.inkFaint : Colors.white),
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? ink.primary
              : ink.divider,
        ),
        trackOutlineColor:
            WidgetStatePropertyAll<Color>(isDark
                ? Colors.transparent
                : ink.inkFaint.withValues(alpha: 0.4)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStatePropertyAll<Color>(ink.primary),
        checkColor: const WidgetStatePropertyAll<Color>(Colors.white),
        side: BorderSide(color: ink.inkFaint, width: 1.4),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppTokens.r1))),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStatePropertyAll<Color>(ink.primary),
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(AppTokens.r2),
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => ink.inkFaint
              .withValues(alpha: states.contains(WidgetState.hovered) ? 0.55 : 0.28),
        ),
        trackColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        crossAxisMargin: 3,
        mainAxisMargin: AppTokens.s2,
        thickness: WidgetStateProperty.resolveWith<double>(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.hovered) ? 9 : 6,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink.ink,
        contentTextStyle:
            AppFonts.text(ink.paper, size: 13.5, height: 1.5),
        actionTextColor: isDark ? ink.primary : ink.surfaceRaised,
        elevation: 0,
        showCloseIcon: false,
        insetPadding: const EdgeInsets.all(AppTokens.s4),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppTokens.r2))),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 380),
        exitDuration: AppTokens.fast,
        preferBelow: false,
        padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s2, vertical: AppTokens.s1),
        decoration: BoxDecoration(
          color: ink.ink,
          borderRadius: const BorderRadius.all(Radius.circular(AppTokens.r1)),
        ),
        textStyle: AppFonts.text(ink.paper, size: 12, height: 1.4),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: ink.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: ink.inkFaint.withValues(alpha: 0.5),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(AppTokens.r4)),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ink.accent,
        selectionColor: ink.selectTint,
        selectionHandleColor: ink.primary,
      ),
    );
  }

  /// 输入框边框（统一圆角，只在聚焦时变色变粗）。
  static OutlineInputBorder _fieldBorder(Color color, {double width = 1.2}) {
    return OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(AppTokens.r2)),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  /// 中文字型排版：字号比西文略大、行高略松，标题不做负字距（中文负字距会糊）。
  static TextTheme _textTheme(AppInk ink) {
    TextStyle st(
      double size, {
      FontWeight weight = FontWeight.w400,
      double height = 1.6,
      Color? color,
      bool serifFace = false,
    }) =>
        AppFonts.text(
          color ?? ink.ink,
          size: size,
          weight: weight,
          height: height,
          serifFace: serifFace,
        );

    return TextTheme(
      displayLarge: st(34, weight: FontWeight.w700, height: 1.25, serifFace: true),
      displayMedium: st(30, weight: FontWeight.w700, height: 1.28, serifFace: true),
      displaySmall: st(26, weight: FontWeight.w700, height: 1.3, serifFace: true),
      headlineLarge: st(24, weight: FontWeight.w700, height: 1.35),
      headlineMedium: st(21, weight: FontWeight.w600, height: 1.4),
      headlineSmall: st(18.5, weight: FontWeight.w600, height: 1.45),
      titleLarge: st(16.5, weight: FontWeight.w600, height: 1.45),
      titleMedium: st(14.5, weight: FontWeight.w600, height: 1.45),
      titleSmall: st(13, weight: FontWeight.w600, height: 1.45, color: ink.inkSoft),
      bodyLarge: st(15, height: AppTokens.lineHeightBody),
      bodyMedium: st(13.5, height: AppTokens.lineHeightBody, color: ink.inkSoft),
      bodySmall: st(12.5, height: 1.55, color: ink.inkSoft),
      labelLarge: st(13.5, weight: FontWeight.w600, height: 1.3),
      labelMedium: st(12.5, weight: FontWeight.w500, height: 1.3, color: ink.inkSoft),
      labelSmall: st(11.5, weight: FontWeight.w500, height: 1.3, color: ink.inkFaint),
    );
  }
}
