//+------------------------------------------------------------------+
//|                                        MT5SignalFull_v11.mq5     |
//|  VERSION 11.0 — MULTI-TIMEFRAME + SMART RE-ENTRY                                     |
//|                                                                  |
//|  แก้ไขจากปัญหาที่พบใน v7 + v8:                                  |
//|  [FIX-1] TP/SL ใหญ่ขึ้น ให้ breathe room พ้น spread             |
//|  [FIX-2] CalcLotSize ใช้ pip-distance แทน USD โดยตรง (v8 bug)   |
//|  [FIX-3] Higher Timeframe Trend Filter (H1 EMA)                  |
//|  [FIX-4] Cooldown เพิ่มเป็น 10 นาที + Consecutive Loss Block    |
//|  [FIX-5] Order Block "freshness" check (ไม่ใช้ OB ที่ break แล้ว)|
//|  [FIX-6] Minimum RR ratio enforce (TP/SL ≥ 1.5)                 |
//|  [FIX-7] Entry ต้องไม่ฝืน HTF — Buy เฉพาะ H1 bull, Sell เฉพาะ  |
//|           H1 bear                                                 |
//|                                                                  |
//|  [FIX-8] Commission คำนวณเข้า TP/SL ทุก trade                   |
//|  [FIX-9] Consecutive Loss ใช้ไฟล์ shared ข้าม EA instances      |
//|  [FIX-10] MaxLotSize = 0.05, RiskPercent = 0.1 (ลด commission)  |
//|  [v11-A] Multi-Timeframe Top-Down: 1D→4H→1H→M15                 |
//|  [v11-B] Smart Re-entry: retrace zone + structure check          |
//|  [v11-C] Adaptive Confidence: สูงขึ้นหลังขาดทุน                 |
//|  รวม Price Action engine จาก v8 + Regime/Session/News จาก v7    |
//+------------------------------------------------------------------+
#property copyright "MT5 Auto Trading v11"
#property version   "11.00"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input string WebhookURL           = "http://10.10.10.45:5000/webhook/webhook";
// [SEC] ต้องตรงกับ WEBHOOK_SECRET ใน .env ของ Flask server
// สร้างด้วย: python -c "import secrets; print(secrets.token_hex(32))"
input string WebhookSecret        = "Somchart38";

// ================================================================
// === CORE INDICATORS                                            ===
// ================================================================
input int    RSIPeriod            = 14;
input int    RSIOBought           = 65;
input int    RSIOSold             = 35;
input int    ATRPeriod            = 14;
input int    ADXPeriod            = 14;
input double ADX_Trending         = 28.0;
input double ADX_Sideways         = 18.0;

// ================================================================
// === [FIX-3] HIGHER TIMEFRAME TREND FILTER                     ===
// === กรอง trade ที่สวน H1 trend                                ===
// ================================================================
input bool   UseHTFFilter         = true;
input ENUM_TIMEFRAMES HTF_Period  = PERIOD_H1;   // Higher Timeframe
input int    HTF_EMA_Fast         = 21;           // EMA Fast บน HTF
input int    HTF_EMA_Slow         = 50;           // EMA Slow บน HTF
// Buy ได้เฉพาะเมื่อ HTF EMA Fast > EMA Slow (HTF bullish)
// Sell ได้เฉพาะเมื่อ HTF EMA Fast < EMA Slow (HTF bearish)

// ================================================================
// === [v11-A] MULTI-TIMEFRAME TOP-DOWN FILTER                   ===
// ================================================================
input bool   UseMTFFilter         = true;
// 1D Bias Filter — ห้ามเทรดสวน daily trend เด็ดขาด
input bool   Use1DFilter          = true;
input int    D1_EMA               = 50;    // EMA50 บน Daily
// 4H Structure Filter
input bool   Use4HFilter          = true;
input int    H4_EMA_Fast          = 21;
input int    H4_EMA_Slow          = 50;
// ถ้า 1D Bull + 4H Bull → Buy confidence bonus +0.2
// ถ้า 1D Bear + 4H Bear → Sell confidence bonus +0.2
// ถ้า 1D กับ Entry ขัดกัน → ห้ามเปิด

// ================================================================
// === [v11-B] SMART RE-ENTRY                                    ===
// ================================================================
input bool   UseSmartReentry      = true;
input int    ReentryMinBars       = 3;     // รอกี่แท่ง M15 หลังปิดไม้ก่อน
input double ReentryZonePct       = 60.0;  // ราคาต้องย้อนกลับมา >= 50% ของ move ก่อน
// ถ้าไม้แรกกำไร → re-entry ง่ายกว่า (confidence ปกติ)
// ถ้าไม้แรกขาดทุน → ต้องการ confidence สูงกว่า

// ================================================================
// === [v11-C] ADAPTIVE CONFIDENCE                               ===
// ================================================================
// confidence threshold ปรับตาม consecutive loss
// 0 loss → minConf ปกติ (0.4 trend / 0.6 caution)
// 1 loss → +0.1
// 2+ loss → +0.2 (เข้มงวดมากขึ้น)
input double ConfLossBonus        = 0.15;  // บวกเพิ่มต่อ consecutive loss

// ================================================================
// === PRICE ACTION SETTINGS (จาก v8 — ปรับ lookback)           ===
// ================================================================
input bool   UseOrderBlock        = true;
input int    OB_Lookback          = 30;           // เพิ่มขึ้นจาก 20 เพื่อหา OB ที่ดีกว่า
input double OB_MinBodyPct        = 55.0;
input double OB_ZoneBuffer        = 0.3;          // เพิ่ม buffer เล็กน้อย
// [FIX-5] OB ต้องไม่ถูก break ซ้ำหลังเกิด
input int    OB_MaxAgeBars        = 50;           // OB เก่าเกิน 50 แท่ง → ไม่ใช้

input bool   UseFVG               = true;
input int    FVG_Lookback         = 15;
input double FVG_MinGapATR        = 0.25;

input bool   UseLiqSweep          = true;
input int    Sweep_Lookback       = 20;
input double Sweep_PenetratePct   = 25.0;

input bool   UseVolumeProfile     = true;
input int    VP_Lookback          = 60;
input int    VP_Zones             = 10;
input double HVN_TopPct           = 20.0;
input double LVN_BottomPct        = 20.0;

input bool   UseMarketStructure   = true;
input int    MS_SwingStrength     = 3;
input int    MS_Lookback          = 40;

// ================================================================
// === NEWS BLACKOUT FILTER                                       ===
// ================================================================
input bool   UseNewsFilter        = true;
input int    NewsMinutesBefore    = 30;
input int    NewsMinutesAfter     = 45;          // เพิ่มจาก 30 → 45 (ตลาด volatile หลังข่าว)
input string News1                = "FRIDAY 1330";
input string News2                = "WEDNESDAY 1800";
input string News3                = "TUESDAY 1330";
input string News4                = "NONE";
input string News5                = "NONE";

// ================================================================
// === SESSION FILTER                                             ===
// ================================================================
input bool   UseSessionFilter     = true;
// เทรดเฉพาะ London + NY Session (GMT)
// London: 07:00-16:00, NY: 13:00-21:00, Overlap: 13:00-16:00

// ================================================================
// === SPREAD + VOLATILITY FILTER                                 ===
// ================================================================
input bool   UseSpreadFilter      = true;
input int    MaxSpreadPoints      = 20;          // จาก 25 → 20 (เข้มขึ้น)
input double MinATRFilter         = 0.00010;     // เพิ่มขึ้น: ต้องการ volatility พอ

// ================================================================
// === [FIX-1] PROFIT / RISK — ปรับให้ใหญ่ขึ้น                 ===
// ================================================================
input double ProfitTargetUSD      = 20.0;        // เพิ่มจาก $5/$8 → $12
input double ProfitExtendedUSD    = 20.0;        // Extended target
input double StopLossUSD          = 6.0;         // เพิ่มจาก $3/$4 → $6
// [FIX-8] Commission ต่อ 1 lot (broker คิด $6/lot → ใส่ 6.0)
input double CommissionPerLot     = 6.0;         // $6 per lot (round-trip = x2)
// [FIX-6] enforce RR ≥ MinRR ก่อนเปิด order
input double MinRR                = 1.5;         // TP/SL ต้อง ≥ 1.5 เสมอ
input double LockProfitPct        = 70.0;
input double TrailStepUSD         = 4.0;
input double MomentumATRMult      = 1.0;

// ================================================================
// === [FIX-11] ATR TRAILING STOP — เริ่มทันทีเมื่อกำไรพอ        ===
// ================================================================
// เมื่อกำไรถึง TrailActivateUSD → เริ่ม trail SL ตาม ATR ทันที
// ไม่ต้องรอถึง ProfitExtendedUSD เหมือนเดิม
input bool   UseATRTrail          = true;
input double TrailActivateUSD     = 5.0;   // เริ่ม trail เมื่อกำไร >= $5
input double TrailATRMult         = 1.5;   // SL ห่างจากราคาปัจจุบัน 1.5x ATR
input double PartialClosePct      = 50.0;  // ปิดกี่ % เมื่อถึง TP1 (0 = ไม่ partial close)
input double TP1_USD              = 12;   // TP1: ปิด partial ที่ $8 กำไร

// ================================================================
// === MONEY MANAGEMENT                                           ===
// ================================================================
input int    MaxTradesPerDay      = 4;           // ลดจาก 5/10 → 4 (คุณภาพเหนือปริมาณ)
input int    MaxPositions         = 1;
// [FIX-4] Cooldown เพิ่มเป็น 10 นาที
input int    CooldownSeconds      = 900;         // 600s = 10 นาที (จาก 45/120)
// [FIX-4] Block เมื่อขาดทุนติดกัน
input int    MaxConsecutiveLoss   = 2;           // หยุดเทรดถ้าขาดทุน N ไม้ติดกัน
input int    ConsLossBlockMinutes = 60;          // หยุดกี่นาทีหลังขาดทุนติดกัน
input bool   AutoTrade            = true;
input ulong  MagicNumber          = 123456;
input double RiskPercent          = 0.5;         // [FIX-10] ลดลงเพื่อ limit lot size
input double MinLotSize           = 0.01;
input double MaxLotSize           = 0.05;         // [FIX-10] cap lot ที่ 0.05 ลด commission risk *****
input bool   UseDailyLimit        = true;
input double DailyLossLimit       = 3.0;
input bool   UseDrawdown          = true;
input double MaxDrawdownPct       = 8.0;         // เข้มขึ้นจาก 10 → 8%

//+------------------------------------------------------------------+
//| STRUCTS                                                           |
//+------------------------------------------------------------------+

struct OrderBlock {
   double   high, low, mid;
   bool     isBullish, isValid;
   datetime time;
   int      barAge;    // [FIX-5] อายุแท่งนับจากเกิด OB
};

struct FairValueGap {
   double   high, low;
   bool     isBullish, isFilled;
   datetime time;
};

struct VPZone {
   double   priceHigh, priceLow, totalVolume;
   bool     isHVN, isLVN;
};

struct PASignal {
   bool   hasBuySetup, hasSellSetup;
   string reasons;
   double confidence;
   double suggestedSL;
};

enum ENUM_TRADE_MODE_V9  { MODE_NORMAL_V9, MODE_EXTENDED_V9 };
enum ENUM_MARKET_REGIME_V9 { REGIME_TRENDING_V9, REGIME_CAUTION_V9, REGIME_SIDEWAYS_V9 };

struct TradeState {
   ulong                ticket;
   ENUM_TRADE_MODE_V9   mode;
   double               peakProfit;
   double               lastTrailStep;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

int handleRSI, handleATR, handleADX;
int handleHTF_EMA_Fast, handleHTF_EMA_Slow; // [FIX-3] HTF handles

// PA Structures cache
OrderBlock    gBullOB[5], gBearOB[5];
int           gBullOBCount = 0, gBearOBCount = 0;
FairValueGap  gBullFVG[5], gBearFVG[5];
int           gBullFVGCount = 0, gBearFVGCount = 0;
VPZone        gVPZones[20];
int           gVPZoneCount = 0;
datetime      gLastBarTime = 0;

// [v11-A] MTF handles
int handleD1_EMA = 0;
int handleH4_EMA_Fast = 0, handleH4_EMA_Slow = 0;

// [v11-B] Re-entry state
datetime gLastCloseBarTime = 0;   // เวลาแท่งที่ปิด trade ล่าสุด
double   gLastClosePrice   = 0;   // ราคาที่ปิด trade ล่าสุด
double   gLastOpenPrice    = 0;   // ราคาที่เปิด trade ล่าสุด
bool     gLastTradeProfit  = false; // trade ล่าสุดกำไรหรือขาดทุน

// Money management
double   gPeakBalance = 0, gDayStartBalance = 0;
datetime gLastDayCheck = 0, gLastDayReset = 0;
bool     gTradingHalted = false;
int      gTradesToday = 0;
datetime gLastTradeClose = 0;

// [FIX-4][FIX-9] Consecutive loss — shared file across EA instances
int      gConsecutiveLoss    = 0;
datetime gConsLossBlockUntil = 0;
bool     gLastTradeWasLoss   = false;
string   CONS_LOSS_FILE      = "ea_cons_loss.txt"; // shared ข้าม pair

TradeState gTrades[10];
int        gTradeCount = 0;

//+------------------------------------------------------------------+
//| [FIX-9] Consecutive Loss — Shared File (ข้าม EA instances)      |
//| ทุก pair EA อ่าน/เขียนไฟล์เดียวกัน → block ได้ทุก pair         |
//+------------------------------------------------------------------+
void WriteConsLossFile(int count, datetime blockUntil)
{
   int h = FileOpen(CONS_LOSS_FILE, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, IntegerToString(count) + "," + IntegerToString((long)blockUntil));
   FileClose(h);
}

void ReadConsLossFile()
{
   if(!FileIsExist(CONS_LOSS_FILE, FILE_COMMON)) return;
   int h = FileOpen(CONS_LOSS_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   string line = FileReadString(h);
   FileClose(h);
   string parts[];
   if(StringSplit(line, ',', parts) >= 2) {
      gConsecutiveLoss    = (int)StringToInteger(parts[0]);
      gConsLossBlockUntil = (datetime)StringToInteger(parts[1]);
   }
}

void ResetConsLossFile()
{
   gConsecutiveLoss    = 0;
   gConsLossBlockUntil = 0;
   WriteConsLossFile(0, 0);
}

//+------------------------------------------------------------------+
//| [v11-A] MULTI-TIMEFRAME TOP-DOWN ANALYSIS                        |
//| คืน bias: 1=Bull, -1=Bear, 0=Mixed/Unclear                       |
//+------------------------------------------------------------------+
int Get1DBias()
{
   if(!Use1DFilter || !UseMTFFilter) return 1; // ถ้าปิด → ผ่านทุกทิศ
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(handleD1_EMA, 0, 0, 2, ema) <= 0) return 0;
   double price[];
   ArraySetAsSeries(price, true);
   if(CopyClose(_Symbol, PERIOD_D1, 0, 2, price) <= 0) return 0;
   // ราคาปัจจุบันเหนือ EMA50 daily = Bull bias
   if(price[0] > ema[0]) return  1;
   if(price[0] < ema[0]) return -1;
   return 0;
}

int Get4HBias()
{
   if(!Use4HFilter || !UseMTFFilter) return 1;
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(handleH4_EMA_Fast, 0, 0, 2, fast) <= 0) return 0;
   if(CopyBuffer(handleH4_EMA_Slow, 0, 0, 2, slow) <= 0) return 0;
   if(fast[0] > slow[0] && fast[1] > slow[1]) return  1; // Bull ยืนยัน 2 แท่ง
   if(fast[0] < slow[0] && fast[1] < slow[1]) return -1; // Bear ยืนยัน 2 แท่ง
   return 0; // กำลัง cross
}

// คืน confidence bonus จาก MTF alignment
double GetMTFBonus(bool isBuy)
{
   int d1 = Get1DBias();
   int h4 = Get4HBias();
   int direction = isBuy ? 1 : -1;

   // ห้ามเทรดสวน 1D เด็ดขาด
   if(d1 != 0 && d1 != direction) return -99.0; // signal ห้ามผ่าน

   double bonus = 0;
   if(d1 == direction) bonus += 0.15; // 1D ยืนยัน
   if(h4 == direction) bonus += 0.10; // 4H ยืนยัน
   return bonus;
}

//+------------------------------------------------------------------+
//| [v11-B] SMART RE-ENTRY CHECK                                     |
//| ตรวจว่าเงื่อนไข re-entry ครบหรือยัง                              |
//+------------------------------------------------------------------+
bool IsReentryReady(bool isBuy)
{
   if(!UseSmartReentry) return true;
   if(gLastCloseBarTime == 0) return true; // ไม้แรก ผ่านเสมอ

   // ต้องรอ ReentryMinBars แท่ง M15 หลังปิดไม้ก่อน
   datetime barTimes[];
   ArraySetAsSeries(barTimes, true);
   if(CopyTime(_Symbol, _Period, 0, 1, barTimes) <= 0) return true;
   if(barTimes[0] <= gLastCloseBarTime) {
      Print("  [v11-B] Re-entry: รอ bar ใหม่");
      return false;
   }

   // ตรวจว่าราคา retrace กลับมาพอไหม
   if(gLastOpenPrice > 0 && gLastClosePrice > 0) {
      double move     = MathAbs(gLastClosePrice - gLastOpenPrice);
      double minRetrace = move * (ReentryZonePct / 100.0);
      double curPrice   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double retrace  = isBuy
                        ? (gLastClosePrice - curPrice) // buy: ราคาย่อลงมา
                        : (curPrice - gLastClosePrice); // sell: ราคาดีดขึ้นมา

      if(move > 0 && retrace < minRetrace) {
         Print("  [v11-B] Re-entry: retrace ", DoubleToString(retrace,5),
               " < min ", DoubleToString(minRetrace,5));
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| [v11-C] ADAPTIVE CONFIDENCE THRESHOLD                            |
//| ยิ่งขาดทุนต่อกัน ยิ่งต้องการ confidence สูงขึ้น                 |
//+------------------------------------------------------------------+
double GetMinConfidence(bool isTrending)
{
   double base = isTrending ? 0.4 : 0.6;
   ReadConsLossFile(); // sync ก่อน
   double adjustment = MathMin(gConsecutiveLoss * ConfLossBonus, 0.3); // cap ที่ +0.3
   double result = base + adjustment;
   if(adjustment > 0)
      Print("  [v11-C] minConf=", DoubleToString(result,2),
            " (base=", DoubleToString(base,2),
            " + loss_adj=", DoubleToString(adjustment,2), ")");
   return result;
}

//+------------------------------------------------------------------+
//| [FIX-3] HTF TREND FILTER                                         |
//| ตรวจทิศทาง trend บน Timeframe สูง ก่อนอนุญาตเปิด order          |
//+------------------------------------------------------------------+
// คืน:  1 = HTF Bullish (อนุญาต Buy)
//       -1 = HTF Bearish (อนุญาต Sell)
//        0 = ไม่ชัด (งดเทรดทั้งสองทิศ)
int GetHTFTrend()
{
   if(!UseHTFFilter) return 1; // ถ้าปิด filter ถือว่า OK ทุกทิศ

   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   // ดึง EMA จาก Higher Timeframe
   if(CopyBuffer(handleHTF_EMA_Fast, 0, 0, 3, emaFast) <= 0) return 0;
   if(CopyBuffer(handleHTF_EMA_Slow, 0, 0, 3, emaSlow) <= 0) return 0;

   bool fastAbove = (emaFast[0] > emaSlow[0]);
   bool fastAbovePrev = (emaFast[1] > emaSlow[1]);

   // Bullish: EMA Fast เหนือ Slow (และยืนยันแท่งก่อนด้วย)
   if(fastAbove && fastAbovePrev)  return  1;
   // Bearish: EMA Fast ต่ำกว่า Slow
   if(!fastAbove && !fastAbovePrev) return -1;

   // กำลัง cross กัน = ไม่ชัด
   return 0;
}

//+------------------------------------------------------------------+
//| ADX REGIME DETECTION                                             |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME_V9 DetectRegime()
{
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(handleADX, 0, 0, 2, adxBuf) <= 0) return REGIME_CAUTION_V9;
   double adx = adxBuf[0];
   if(adx >= ADX_Trending) return REGIME_TRENDING_V9;
   if(adx >= ADX_Sideways) return REGIME_CAUTION_V9;
   return REGIME_SIDEWAYS_V9;
}

//+------------------------------------------------------------------+
//| NEWS BLACKOUT FILTER                                             |
//+------------------------------------------------------------------+
bool ParseNewsTime(string s, int &dow, int &h, int &m)
{
   if(s == "NONE" || s == "") return false;
   StringToUpper(s);
   string p[];
   if(StringSplit(s, ' ', p) < 2) return false;
   string d = p[0], t = p[1];
   if(d == "MONDAY")         dow = 1;
   else if(d == "TUESDAY")   dow = 2;
   else if(d == "WEDNESDAY") dow = 3;
   else if(d == "THURSDAY")  dow = 4;
   else if(d == "FRIDAY")    dow = 5;
   else return false;
   if(StringLen(t) != 4) return false;
   h = (int)StringToInteger(StringSubstr(t, 0, 2));
   m = (int)StringToInteger(StringSubstr(t, 2, 2));
   return true;
}

bool IsNewsBlackout()
{
   if(!UseNewsFilter) return false;
   datetime gmt = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(gmt, mdt);
   int curMins = mdt.hour * 60 + mdt.min;
   string nl[] = {News1, News2, News3, News4, News5};
   for(int i = 0; i < 5; i++) {
      int nd, nh, nm;
      if(!ParseNewsTime(nl[i], nd, nh, nm)) continue;
      if(nd != mdt.day_of_week) continue;
      int diff = curMins - (nh * 60 + nm);
      if(diff >= -NewsMinutesBefore && diff <= NewsMinutesAfter) {
         Print("  [News] BLACKOUT | diff:", diff, "min");
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| SESSION FILTER                                                    |
//+------------------------------------------------------------------+
bool IsSessionOK()
{
   if(!UseSessionFilter) return true;
   MqlDateTime mdt;
   TimeToStruct(TimeGMT(), mdt);
   int h = mdt.hour;
   // London 07-16 หรือ NY 13-21
   bool ok = (h >= 7 && h < 21);
   if(!ok) Print("  [Session] Outside GMT ", h);
   return ok;
}

//+------------------------------------------------------------------+
//| PA-1: ORDER BLOCK DETECTION (v8 + FIX-5 age check)              |
//+------------------------------------------------------------------+
void DetectOrderBlocks(double atr)
{
   gBullOBCount = 0;
   gBearOBCount = 0;

   double opens[], closes[], highs[], lows[];
   ArraySetAsSeries(opens,  true); ArraySetAsSeries(closes, true);
   ArraySetAsSeries(highs,  true); ArraySetAsSeries(lows,   true);

   int lb = OB_Lookback + 5;
   if(CopyOpen (_Symbol, _Period, 0, lb, opens)  <= 0) return;
   if(CopyClose(_Symbol, _Period, 0, lb, closes) <= 0) return;
   if(CopyHigh (_Symbol, _Period, 0, lb, highs)  <= 0) return;
   if(CopyLow  (_Symbol, _Period, 0, lb, lows)   <= 0) return;

   datetime times[];
   ArraySetAsSeries(times, true);
   CopyTime(_Symbol, _Period, 0, lb, times);

   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = OB_Lookback; i >= 3; i--)
   {
      // [FIX-5] OB เก่าเกิน OB_MaxAgeBars → ข้ามไป
      if(i > OB_MaxAgeBars) continue;

      double range  = highs[i] - lows[i];
      double body   = MathAbs(closes[i] - opens[i]);
      if(range <= 0) continue;
      double bodyPct = (body / range) * 100.0;
      if(bodyPct < OB_MinBodyPct) continue;

      bool isBearCandle = (closes[i] < opens[i]);

      // ===== BULLISH OB =====
      if(isBearCandle && gBullOBCount < 5)
      {
         double moveUp = closes[i-2] - closes[i];
         if(moveUp > atr * 1.5)
         {
            // [FIX-5] ตรวจ: ราคาต้องไม่ลงไป break ต่ำกว่า OB low หลังจาก OB เกิดขึ้น
            bool obBroken = false;
            for(int k = i-1; k >= 1; k--) {
               if(lows[k] < lows[i] - atr * 0.3) { obBroken = true; break; }
            }
            if(!obBroken && curPrice > lows[i])
            {
               OrderBlock ob;
               ob.high      = opens[i];
               ob.low       = lows[i];
               ob.mid       = (ob.high + ob.low) / 2.0;
               ob.isBullish = true;
               ob.isValid   = true;
               ob.time      = times[i];
               ob.barAge    = i;
               gBullOB[gBullOBCount++] = ob;
            }
         }
      }

      // ===== BEARISH OB =====
      if(!isBearCandle && gBearOBCount < 5)
      {
         double moveDown = closes[i] - closes[i-2];
         if(moveDown > atr * 1.5)
         {
            // [FIX-5] ตรวจ: ราคาต้องไม่ขึ้นไป break เหนือ OB high หลัง OB เกิด
            bool obBroken = false;
            for(int k = i-1; k >= 1; k--) {
               if(highs[k] > highs[i] + atr * 0.3) { obBroken = true; break; }
            }
            if(!obBroken && curPrice < highs[i])
            {
               OrderBlock ob;
               ob.high      = highs[i];
               ob.low       = closes[i];
               ob.mid       = (ob.high + ob.low) / 2.0;
               ob.isBullish = false;
               ob.isValid   = true;
               ob.time      = times[i];
               ob.barAge    = i;
               gBearOB[gBearOBCount++] = ob;
            }
         }
      }
   }

   Print("  [PA-OB] Bull:", gBullOBCount, " Bear:", gBearOBCount);
}

//+------------------------------------------------------------------+
//| PA-2: FVG DETECTION                                              |
//+------------------------------------------------------------------+
void DetectFVG(double atr)
{
   gBullFVGCount = 0;
   gBearFVGCount = 0;

   double highs[], lows[], closes[];
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(closes, true);

   int lb = FVG_Lookback + 3;
   if(CopyHigh (_Symbol, _Period, 0, lb, highs)  <= 0) return;
   if(CopyLow  (_Symbol, _Period, 0, lb, lows)   <= 0) return;
   if(CopyClose(_Symbol, _Period, 0, lb, closes) <= 0) return;

   datetime times[];
   ArraySetAsSeries(times, true);
   CopyTime(_Symbol, _Period, 0, lb, times);

   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = FVG_Lookback; i >= 2; i--)
   {
      // Bullish FVG
      double gapHigh = lows[i-1];
      double gapLow  = highs[i+1];
      if(gapHigh > gapLow && (gapHigh - gapLow) >= FVG_MinGapATR * atr)
      {
         if(curPrice > gapLow && gBullFVGCount < 5) {
            FairValueGap fvg;
            fvg.high = gapHigh; fvg.low = gapLow;
            fvg.isBullish = true;
            fvg.isFilled  = (curPrice < gapHigh);
            fvg.time = times[i];
            gBullFVG[gBullFVGCount++] = fvg;
         }
      }

      // Bearish FVG
      double bgapHigh = lows[i+1];
      double bgapLow  = highs[i-1];
      if(bgapHigh > bgapLow && (bgapHigh - bgapLow) >= FVG_MinGapATR * atr)
      {
         if(curPrice < bgapHigh && gBearFVGCount < 5) {
            FairValueGap fvg;
            fvg.high = bgapHigh; fvg.low = bgapLow;
            fvg.isBullish = false;
            fvg.isFilled  = (curPrice > bgapLow);
            fvg.time = times[i];
            gBearFVG[gBearFVGCount++] = fvg;
         }
      }
   }

   Print("  [PA-FVG] Bull:", gBullFVGCount, " Bear:", gBearFVGCount);
}

//+------------------------------------------------------------------+
//| PA-3: LIQUIDITY SWEEP                                            |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(bool lookForBullish, double atr)
{
   if(!UseLiqSweep) return false;

   double highs[], lows[], closes[], opens[];
   ArraySetAsSeries(highs,  true); ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(closes, true); ArraySetAsSeries(opens,  true);

   int lb = Sweep_Lookback + 3;
   if(CopyHigh (_Symbol, _Period, 0, lb, highs)  <= 0) return false;
   if(CopyLow  (_Symbol, _Period, 0, lb, lows)   <= 0) return false;
   if(CopyClose(_Symbol, _Period, 0, lb, closes) <= 0) return false;
   if(CopyOpen (_Symbol, _Period, 0, lb, opens)  <= 0) return false;

   if(lookForBullish)
   {
      double swingLevel = lows[ArrayMinimum(lows, 2, Sweep_Lookback-2)];
      double lastLow    = lows[1];
      double lastClose  = closes[1];
      double lastRange  = highs[1] - lows[1];
      if(lastRange <= 0) return false;

      bool penetrated  = (lastLow < swingLevel);
      bool closedBack  = (lastClose > swingLevel);
      bool deepEnough  = ((swingLevel - lastLow) > atr * 0.1);
      double closePct  = ((lastClose - lastLow) / lastRange) * 100;
      bool strongClose = (closePct >= Sweep_PenetratePct);

      if(penetrated && closedBack && deepEnough && strongClose) {
         Print("  [PA-Sweep] BULLISH SWEEP | SwingLow:", DoubleToString(swingLevel, 5),
               " Close%:", DoubleToString(closePct, 1));
         return true;
      }
   }
   else
   {
      double swingLevel = highs[ArrayMaximum(highs, 2, Sweep_Lookback-2)];
      double lastHigh   = highs[1];
      double lastClose  = closes[1];
      double lastRange  = highs[1] - lows[1];
      if(lastRange <= 0) return false;

      bool penetrated  = (lastHigh > swingLevel);
      bool closedBack  = (lastClose < swingLevel);
      bool deepEnough  = ((lastHigh - swingLevel) > atr * 0.1);
      double closePct  = ((lastHigh - lastClose) / lastRange) * 100;
      bool strongClose = (closePct >= Sweep_PenetratePct);

      if(penetrated && closedBack && deepEnough && strongClose) {
         Print("  [PA-Sweep] BEARISH SWEEP | SwingHigh:", DoubleToString(swingLevel, 5),
               " Close%:", DoubleToString(closePct, 1));
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| PA-4: VOLUME PROFILE                                             |
//+------------------------------------------------------------------+
void BuildVolumeProfile()
{
   if(!UseVolumeProfile) { gVPZoneCount = 0; return; }

   double highs[], lows[];
   long   volumes[];
   ArraySetAsSeries(highs,   true);
   ArraySetAsSeries(lows,    true);
   ArraySetAsSeries(volumes, true);

   if(CopyHigh     (_Symbol, _Period, 0, VP_Lookback, highs)   <= 0) return;
   if(CopyLow      (_Symbol, _Period, 0, VP_Lookback, lows)    <= 0) return;
   if(CopyTickVolume(_Symbol, _Period, 0, VP_Lookback, volumes) <= 0) return;

   double rangeHigh = highs[ArrayMaximum(highs, 0, VP_Lookback)];
   double rangeLow  = lows[ArrayMinimum(lows,   0, VP_Lookback)];
   double zoneSize  = (rangeHigh - rangeLow) / VP_Zones;
   if(zoneSize <= 0) return;

   gVPZoneCount = VP_Zones;
   for(int z = 0; z < VP_Zones; z++) {
      gVPZones[z].priceLow    = rangeLow + z * zoneSize;
      gVPZones[z].priceHigh   = rangeLow + (z+1) * zoneSize;
      gVPZones[z].totalVolume = 0;
      gVPZones[z].isHVN       = false;
      gVPZones[z].isLVN       = false;
   }

   for(int i = 0; i < VP_Lookback; i++) {
      double candleRange = highs[i] - lows[i];
      if(candleRange <= 0) continue;
      for(int z = 0; z < VP_Zones; z++) {
         double overlap = MathMin(highs[i], gVPZones[z].priceHigh)
                        - MathMax(lows[i],  gVPZones[z].priceLow);
         if(overlap > 0)
            gVPZones[z].totalVolume += volumes[i] * (overlap / candleRange);
      }
   }

   double maxVol = 0, minVol = DBL_MAX;
   for(int z = 0; z < VP_Zones; z++) {
      if(gVPZones[z].totalVolume > maxVol) maxVol = gVPZones[z].totalVolume;
      if(gVPZones[z].totalVolume < minVol) minVol = gVPZones[z].totalVolume;
   }
   double volRange  = maxVol - minVol;
   double hvnThresh = maxVol - (volRange * HVN_TopPct    / 100.0);
   double lvnThresh = minVol + (volRange * LVN_BottomPct / 100.0);

   int hvnCount = 0, lvnCount = 0;
   for(int z = 0; z < VP_Zones; z++) {
      if(gVPZones[z].totalVolume >= hvnThresh) { gVPZones[z].isHVN = true; hvnCount++; }
      if(gVPZones[z].totalVolume <= lvnThresh) { gVPZones[z].isLVN = true; lvnCount++; }
   }

   Print("  [PA-VP] HVN:", hvnCount, " LVN:", lvnCount);
}

bool IsNearHVN(double price, double buf)
{
   for(int z = 0; z < gVPZoneCount; z++)
      if(gVPZones[z].isHVN &&
         price >= gVPZones[z].priceLow - buf &&
         price <= gVPZones[z].priceHigh + buf)
         return true;
   return false;
}

bool IsInLVN(double price)
{
   for(int z = 0; z < gVPZoneCount; z++)
      if(gVPZones[z].isLVN &&
         price >= gVPZones[z].priceLow &&
         price <= gVPZones[z].priceHigh)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| PA-5: MARKET STRUCTURE                                           |
//+------------------------------------------------------------------+
bool IsBullishStructure()
{
   if(!UseMarketStructure) return true;
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, _Period, 0, MS_Lookback, highs) <= 0) return false;
   if(CopyLow (_Symbol, _Period, 0, MS_Lookback, lows)  <= 0) return false;

   int shIdx[2], slIdx[2], shCnt = 0, slCnt = 0;
   for(int i = MS_SwingStrength; i < MS_Lookback - MS_SwingStrength && (shCnt < 2 || slCnt < 2); i++) {
      if(shCnt < 2) {
         bool isH = true;
         for(int j = 1; j <= MS_SwingStrength; j++)
            if(highs[i] <= highs[i-j] || highs[i] <= highs[i+j]) { isH = false; break; }
         if(isH) shIdx[shCnt++] = i;
      }
      if(slCnt < 2) {
         bool isL = true;
         for(int j = 1; j <= MS_SwingStrength; j++)
            if(lows[i] >= lows[i-j] || lows[i] >= lows[i+j]) { isL = false; break; }
         if(isL) slIdx[slCnt++] = i;
      }
   }
   if(shCnt < 2 || slCnt < 2) return false;
   return (highs[shIdx[0]] > highs[shIdx[1]]) && (lows[slIdx[0]] > lows[slIdx[1]]);
}

bool IsBearishStructure()
{
   if(!UseMarketStructure) return true;
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, _Period, 0, MS_Lookback, highs) <= 0) return false;
   if(CopyLow (_Symbol, _Period, 0, MS_Lookback, lows)  <= 0) return false;

   int shIdx[2], slIdx[2], shCnt = 0, slCnt = 0;
   for(int i = MS_SwingStrength; i < MS_Lookback - MS_SwingStrength && (shCnt < 2 || slCnt < 2); i++) {
      if(shCnt < 2) {
         bool isH = true;
         for(int j = 1; j <= MS_SwingStrength; j++)
            if(highs[i] <= highs[i-j] || highs[i] <= highs[i+j]) { isH = false; break; }
         if(isH) shIdx[shCnt++] = i;
      }
      if(slCnt < 2) {
         bool isL = true;
         for(int j = 1; j <= MS_SwingStrength; j++)
            if(lows[i] >= lows[i-j] || lows[i] >= lows[i+j]) { isL = false; break; }
         if(isL) slIdx[slCnt++] = i;
      }
   }
   if(shCnt < 2 || slCnt < 2) return false;
   return (highs[shIdx[0]] < highs[shIdx[1]]) && (lows[slIdx[0]] < lows[slIdx[1]]);
}

//+------------------------------------------------------------------+
//| MAIN PA ANALYSIS                                                  |
//+------------------------------------------------------------------+
PASignal AnalyzePriceAction(double atr, double curPrice)
{
   PASignal sig;
   sig.hasBuySetup  = false;
   sig.hasSellSetup = false;
   sig.reasons      = "";
   sig.confidence   = 0.0;
   sig.suggestedSL  = 0;

   double buffer    = OB_ZoneBuffer * atr;
   int    buyScore  = 0, sellScore = 0;
   string buyR = "", sellR = "";

   // OB check
   if(UseOrderBlock) {
      for(int i = 0; i < gBullOBCount; i++) {
         if(curPrice >= gBullOB[i].low - buffer && curPrice <= gBullOB[i].high + buffer) {
            buyScore++; buyR += "OB ";
            sig.suggestedSL = gBullOB[i].low - atr * 0.5;
            break;
         }
      }
      for(int i = 0; i < gBearOBCount; i++) {
         if(curPrice >= gBearOB[i].low - buffer && curPrice <= gBearOB[i].high + buffer) {
            sellScore++; sellR += "OB ";
            sig.suggestedSL = gBearOB[i].high + atr * 0.5;
            break;
         }
      }
   }

   // FVG check
   if(UseFVG) {
      for(int i = 0; i < gBullFVGCount; i++) {
         if(curPrice >= gBullFVG[i].low && curPrice <= gBullFVG[i].high) {
            buyScore++; buyR += "FVG "; break;
         }
      }
      for(int i = 0; i < gBearFVGCount; i++) {
         if(curPrice >= gBearFVG[i].low && curPrice <= gBearFVG[i].high) {
            sellScore++; sellR += "FVG "; break;
         }
      }
   }

   // Sweep — น้ำหนัก 2
   if(UseLiqSweep) {
      if(DetectLiquiditySweep(true,  atr)) { buyScore  += 2; buyR  += "SWEEP "; }
      if(DetectLiquiditySweep(false, atr)) { sellScore += 2; sellR += "SWEEP "; }
   }

   // Volume Profile
   if(UseVolumeProfile) {
      if(IsNearHVN(curPrice, buffer)) { buyScore++;  sellScore++; buyR  += "HVN "; sellR += "HVN "; }
      if(IsInLVN(curPrice))           { buyScore++;  sellScore++; buyR  += "LVN "; sellR += "LVN "; }
   }

   // Market Structure
   if(UseMarketStructure) {
      if(IsBullishStructure()) { buyScore++;  buyR  += "MS_BULL "; }
      if(IsBearishStructure()) { sellScore++; sellR += "MS_BEAR "; }
   }

   // ต้องการ score >= 2 component ยืนยัน
   int minScore = 2;
   if(buyScore >= minScore) {
      sig.hasBuySetup = true;
      sig.confidence  = MathMin(1.0, buyScore / 5.0);
      sig.reasons     = buyR;
      if(sig.suggestedSL == 0) sig.suggestedSL = curPrice - atr * 2.5;
   }
   if(sellScore >= minScore && sellScore >= buyScore) {
      sig.hasSellSetup = true;
      sig.confidence   = MathMax(sig.confidence, MathMin(1.0, sellScore / 5.0));
      sig.reasons      = sellR;
      if(sig.suggestedSL == 0) sig.suggestedSL = curPrice + atr * 2.5;
   }

   Print("  [PA] Buy:", buyScore, "[", buyR, "] Sell:", sellScore, "[", sellR, "] Conf:", DoubleToString(sig.confidence, 2));
   return sig;
}

//+------------------------------------------------------------------+
//| [FIX-2] CALC LOT SIZE — แก้สูตรให้ใช้ pip distance ถูกต้อง     |
//| เหมือน v7 (ซึ่งถูกต้องแล้ว) ไม่ใช่ v8 (ที่ใช้ risk/slUSD โดยตรง)|
//+------------------------------------------------------------------+
double CalcLotSize(double slUSD)
{
   if(slUSD <= 0) return MinLotSize;
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * (RiskPercent / 100.0);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double ptVal    = (tickSz > 0) ? tickVal / tickSz : 0;
   if(ptVal <= 0) return MinLotSize;

   // คำนวณ SL distance (เป็น price point) จาก slUSD
   // เริ่มต้นด้วย test lot เพื่อหา pip value
   double testLot   = 0.01;
   double slDist    = slUSD / (testLot * ptVal);   // distance ใน price points สำหรับ 0.01 lot
   double lotFinal  = riskAmt / (slDist * ptVal);  // lot จริงที่ risk ตามที่กำหนด
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lotFinal = MathFloor(lotFinal / step) * step;
   lotFinal = MathMax(lotFinal, MinLotSize);
   lotFinal = MathMin(lotFinal, MaxLotSize);
   return lotFinal;
}

//+------------------------------------------------------------------+
//| [FIX-6][FIX-8] ตรวจ RR Ratio โดยคิด Commission เข้าไปด้วย     |
//+------------------------------------------------------------------+
// คำนวณ commission จริงสำหรับ lot ที่จะเปิด
double CalcCommission(double lot)
{
   // round-trip = เปิด + ปิด = x2
   return CommissionPerLot * lot * 2.0;
}

bool CheckRRRatio(double tpUSD, double slUSD, double lot)
{
   if(slUSD <= 0) return false;
   double commission = CalcCommission(lot);
   // net profit หลังหัก commission
   double netTP = tpUSD - commission;
   // net loss รวม commission
   double netSL = slUSD + commission;
   if(netTP <= 0) {
      Print("  [FIX-8] TP ไม่คุ้ม commission: TP=$", DoubleToString(tpUSD,2),
            " Comm=$", DoubleToString(commission,2));
      return false;
   }
   double rr = netTP / netSL;
   if(rr < MinRR) {
      Print("  [FIX-6][FIX-8] RR (net):", DoubleToString(rr,2),
            " < ", DoubleToString(MinRR,1),
            " | TP=$", DoubleToString(netTP,2),
            " SL=$", DoubleToString(netSL,2),
            " Comm=$", DoubleToString(commission,2));
      return false;
   }
   Print("  [FIX-8] RR OK: ", DoubleToString(rr,2),
         "x | netTP=$", DoubleToString(netTP,2),
         " netSL=$", DoubleToString(netSL,2),
         " Comm=$", DoubleToString(commission,2));
   return true;
}

//+------------------------------------------------------------------+
//| DAILY LIMIT + DRAWDOWN                                           |
//+------------------------------------------------------------------+
bool CheckDailyLimit()
{
   if(!UseDailyLimit) return true;
   datetime now = TimeCurrent();
   MqlDateTime mdt;
   TimeToStruct(now, mdt);
   datetime today = now - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   if(today != gLastDayCheck) {
      gDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      gLastDayCheck = today;
   }
   double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (gDayStartBalance > 0) ? ((gDayStartBalance - bal) / gDayStartBalance) * 100 : 0;
   if(lossPct >= DailyLossLimit) {
      Print("  [MM] Daily limit:", DoubleToString(lossPct, 2), "%");
      return false;
   }
   return true;
}

bool CheckDrawdown()
{
   if(!UseDrawdown) return true;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > gPeakBalance) gPeakBalance = bal;
   double dd = (gPeakBalance > 0) ? ((gPeakBalance - bal) / gPeakBalance) * 100 : 0;
   if(dd >= MaxDrawdownPct) {
      Print("  [MM] Drawdown:", DoubleToString(dd, 2), "%");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| [FIX-4] CONSECUTIVE LOSS BLOCK                                   |
//+------------------------------------------------------------------+
bool IsConsecutiveLossBlocked()
{
   if(MaxConsecutiveLoss <= 0) return false;
   // [FIX-9] อ่านจากไฟล์ shared ทุกครั้งที่ตรวจ
   ReadConsLossFile();
   if(gConsLossBlockUntil > 0 && TimeCurrent() < gConsLossBlockUntil) {
      int remaining = (int)((gConsLossBlockUntil - TimeCurrent()) / 60);
      Print("  [FIX-9] ConsLoss BLOCK — รออีก ", remaining, " นาที (shared file)");
      return true;
   }
   // block หมดแล้ว reset
   if(gConsLossBlockUntil > 0 && TimeCurrent() >= gConsLossBlockUntil)
      ResetConsLossFile();
   return false;
}

//+------------------------------------------------------------------+
//| TRADE STATE MANAGEMENT                                           |
//+------------------------------------------------------------------+
int FindTradeState(ulong t) { for(int i = 0; i < gTradeCount; i++) if(gTrades[i].ticket == t) return i; return -1; }

void AddTradeState(ulong t)
{
   if(gTradeCount >= 10) return;
   gTrades[gTradeCount].ticket       = t;
   gTrades[gTradeCount].mode        = MODE_NORMAL_V9;
   gTrades[gTradeCount].peakProfit  = 0;
   gTrades[gTradeCount].lastTrailStep = 0;
   gTradeCount++;
}

void RemoveTradeState(ulong t)
{
   int idx = FindTradeState(t);
   if(idx < 0) return;
   for(int i = idx; i < gTradeCount - 1; i++) gTrades[i] = gTrades[i+1];
   gTradeCount--;
}

//+------------------------------------------------------------------+
//| CLOSE POSITION + อัปเดต consecutive loss                        |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, double profit, string reason)
{
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_DEAL; req.symbol = _Symbol; req.position = ticket;
   req.volume   = PositionGetDouble(POSITION_VOLUME);
   req.type     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price    = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.deviation = 10; req.type_filling = ORDER_FILLING_IOC;

   if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
   {
      gLastTradeClose = TimeCurrent();
      RemoveTradeState(ticket);
      Print("  CLOSED:", ticket, " P:$", DoubleToString(profit, 2), " ", reason);

      // [v11-B] บันทึก state สำหรับ re-entry
      datetime bt[]; ArraySetAsSeries(bt, true);
      if(CopyTime(_Symbol, _Period, 0, 1, bt) > 0) gLastCloseBarTime = bt[0];
      gLastTradeProfit = (profit > 0);

      // [FIX-4][FIX-9] อัปเดต consecutive loss + เขียน shared file
      ReadConsLossFile(); // sync ก่อน
      if(profit < 0) {
         gConsecutiveLoss++;
         if(gConsecutiveLoss >= MaxConsecutiveLoss) {
            gConsLossBlockUntil = TimeCurrent() + ConsLossBlockMinutes * 60;
            Print("  [FIX-9] ConsLoss:", gConsecutiveLoss,
                  " — BLOCK ทุก EA ", ConsLossBlockMinutes, " นาที");
         }
         WriteConsLossFile(gConsecutiveLoss, gConsLossBlockUntil); // บันทึก shared
      } else {
         ResetConsLossFile(); // กำไร reset ทุก pair
      }

      if(StringFind(reason, "TP") >= 0 || StringFind(reason, "DPL") >= 0)
         gTradesToday++;

      SendWebhookClose(ticket, profit, reason);
   }
}

//+------------------------------------------------------------------+
//| MOVE SL — helper ส่ง SLTP order                                 |
//+------------------------------------------------------------------+
bool MoveSL(ulong ticket, double newSL, double curTP)
{
   MqlTradeRequest rq = {}; MqlTradeResult rs_ = {};
   rq.action   = TRADE_ACTION_SLTP;
   rq.symbol   = _Symbol;
   rq.position = ticket;
   rq.sl       = newSL;
   rq.tp       = curTP;
   return (OrderSend(rq, rs_) && rs_.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//| [FIX-11] MANAGE PROFIT — ATR Trail + Partial Close + DPL        |
//|                                                                  |
//| Flow:                                                            |
//|  1. Hard SL: ปิดทันทีถ้าขาดทุนเกิน StopLossUSD                 |
//|  2. Partial Close (TP1): ปิด 50% เมื่อกำไรถึง TP1_USD           |
//|     → เก็บกำไรบางส่วน + ปล่อย 50% วิ่งต่อด้วย trail            |
//|  3. ATR Trail: เริ่มทันทีเมื่อกำไร >= TrailActivateUSD          |
//|     → SL ขยับตาม curPrice - TrailATRMult*ATR (buy)              |
//|     → lock กำไรไว้ ถ้าราคาย่อแรง SL โดนก็ยังได้กำไร            |
//|  4. Full Close (TP): ปิดทั้งหมดเมื่อถึง ProfitTargetUSD        |
//|  5. Extended: ถ้ากำไรเกิน ProfitExtendedUSD → trail แบบ DPL    |
//+------------------------------------------------------------------+
void ManageDPL(double atr)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;

      double profit  = PositionGetDouble(POSITION_PROFIT);
      double curP    = PositionGetDouble(POSITION_PRICE_CURRENT);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);
      double curVol  = PositionGetDouble(POSITION_VOLUME);
      long   posType = PositionGetInteger(POSITION_TYPE);
      int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      int si = FindTradeState(ticket);
      if(si < 0) { AddTradeState(ticket); si = FindTradeState(ticket); }
      if(si < 0) continue;

      if(profit > gTrades[si].peakProfit) gTrades[si].peakProfit = profit;

      // ── 1. HARD STOP LOSS ────────────────────────────────────────
      if(profit <= -StopLossUSD) {
         ClosePosition(ticket, profit, "SL_HARD");
         continue;
      }

      // ── 2. PARTIAL CLOSE @ TP1 ───────────────────────────────────
      // ปิด PartialClosePct% ทันทีเมื่อกำไรถึง TP1_USD
      // ทำครั้งเดียว (ตรวจจาก lastTrailStep = -1 หมายความว่ายังไม่ partial)
      if(UseATRTrail && PartialClosePct > 0
         && profit >= TP1_USD
         && gTrades[si].lastTrailStep == 0)
      {
         double closeVol = NormalizeDouble(curVol * (PartialClosePct / 100.0),
                           (int)MathLog10(1.0 / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)));
         closeVol = MathMax(closeVol, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

         if(closeVol < curVol) {
            MqlTradeRequest rq = {}; MqlTradeResult rs_ = {};
            rq.action      = TRADE_ACTION_DEAL;
            rq.symbol      = _Symbol;
            rq.position    = ticket;
            rq.volume      = closeVol;
            rq.type        = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            rq.price       = (rq.type == ORDER_TYPE_SELL)
                             ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            rq.deviation   = 10;
            rq.type_filling = ORDER_FILLING_IOC;
            rq.comment     = "PartialClose_TP1";

            if(OrderSend(rq, rs_) && rs_.retcode == TRADE_RETCODE_DONE) {
               gTrades[si].lastTrailStep = -1; // mark ว่า partial done แล้ว
               Print("  [TRAIL] Partial Close ", DoubleToString(PartialClosePct,0),
                     "% | vol=", DoubleToString(closeVol,2),
                     " | P=$", DoubleToString(profit,2));
            }
         } else {
            // lot น้อยเกินแบ่งไม่ได้ → close ทั้งหมดเลย
            ClosePosition(ticket, profit, "TP1_FULL");
            continue;
         }
      }

      // ── 3. ATR TRAILING STOP ─────────────────────────────────────
      // เริ่มทันทีเมื่อกำไร >= TrailActivateUSD
      if(UseATRTrail && profit >= TrailActivateUSD)
      {
         double newSL = (posType == POSITION_TYPE_BUY)
                        ? NormalizeDouble(curP - TrailATRMult * atr, digits)
                        : NormalizeDouble(curP + TrailATRMult * atr, digits);

         // SL ต้องขยับไปทิศทางที่ดีขึ้นเท่านั้น (ไม่ถอยหลัง)
         bool improved = (posType == POSITION_TYPE_BUY)
                         ? (newSL > curSL + SymbolInfoDouble(_Symbol, SYMBOL_POINT))
                         : (curSL == 0 || newSL < curSL - SymbolInfoDouble(_Symbol, SYMBOL_POINT));

         if(improved) {
            if(MoveSL(ticket, newSL, curTP))
               Print("  [TRAIL] ATR SL→", DoubleToString(newSL, digits),
                     " | P=$", DoubleToString(profit, 2),
                     " | Peak=$", DoubleToString(gTrades[si].peakProfit, 2));
         }
      }

      // ── 4. FULL TP ───────────────────────────────────────────────
      if(profit >= ProfitTargetUSD) {
         ClosePosition(ticket, profit, "TP_FULL");
         continue;
      }

      // ── 5. EXTENDED DPL (กำไรสูงมาก) ────────────────────────────
      if(gTrades[si].mode == MODE_NORMAL_V9 && profit >= ProfitExtendedUSD) {
         gTrades[si].mode = MODE_EXTENDED_V9;
         gTrades[si].lastTrailStep = profit;
         Print("  [DPL] EXTENDED P:$", DoubleToString(profit, 2));
      }

      if(gTrades[si].mode == MODE_EXTENDED_V9) {
         double lock = gTrades[si].peakProfit * (LockProfitPct / 100.0);
         if(profit <= lock && profit > 0) { ClosePosition(ticket, profit, "DPL_PULLBACK"); continue; }
         if(profit < 0)                   { ClosePosition(ticket, profit, "DPL_REVERSE");  continue; }
      }
   }
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double atr, PASignal &sig)
{
   double lotSize = CalcLotSize(StopLossUSD); // [FIX-2] คำนวณ lot ก่อน
   // [FIX-6][FIX-8] ตรวจ RR พร้อม commission
   if(!CheckRRRatio(ProfitTargetUSD, StopLossUSD, lotSize)) return;
   double price   = (type == ORDER_TYPE_BUY)
                    ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts_  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pv   = (ts_ > 0) ? tv / ts_ : 0;
   if(pv <= 0) return;

   double tpDist = ProfitTargetUSD / (lotSize * pv);
   double slDist = StopLossUSD     / (lotSize * pv);

   double sl, tp;
   if(type == ORDER_TYPE_BUY) {
      sl = NormalizeDouble(price - slDist, digits);
      tp = NormalizeDouble(price + tpDist, digits);
   } else {
      sl = NormalizeDouble(price + slDist, digits);
      tp = NormalizeDouble(price - tpDist, digits);
   }

   // [FIX-8] log net values ก่อนส่ง order
   double commission = CalcCommission(lotSize);
   Print("  [v10] lot=", DoubleToString(lotSize,2),
         " | TP=$", DoubleToString(ProfitTargetUSD,2),
         " | SL=$", DoubleToString(StopLossUSD,2),
         " | Comm=$", DoubleToString(commission,2),
         " | netTP=$", DoubleToString(ProfitTargetUSD-commission,2));

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL; req.symbol = _Symbol; req.volume = lotSize;
   req.type         = type; req.price = price; req.sl = sl; req.tp = tp;
   req.deviation    = 10; req.magic = MagicNumber;
   req.comment      = StringFormat("v10|%s|C%.0f%%", sig.reasons, sig.confidence * 100);
   req.type_filling = ORDER_FILLING_IOC;

   if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
      AddTradeState(res.order);
      Print("  [v9] Trade OK | Ticket:", res.order,
            " | Lot:", DoubleToString(lotSize, 2),
            " | SL:", DoubleToString(sl, digits),
            " | TP:", DoubleToString(tp, digits),
            " | PA:", sig.reasons,
            " | Conf:", DoubleToString(sig.confidence, 2));
   } else {
      Print("  [v9] Trade FAILED | retcode:", res.retcode);
   }
}

int CountPositions()
{
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber) c++;
   }
   return c;
}

//+------------------------------------------------------------------+
//| WEBHOOK                                                           |
//| [SEC] ทุก request ส่ง X-Webhook-Secret header ไปด้วยเสมอ        |
//+------------------------------------------------------------------+

// helper: สร้าง header พร้อม secret
string BuildWebhookHeaders()
{
   return StringFormat(
      "Content-Type: application/json\r\nX-Webhook-Secret: %s\r\n",
      WebhookSecret);
}

void SendWebhookClose(ulong ticket, double profit, string reason)
{
   string json = StringFormat(
      "{\"sym\":\"%s\",\"action\":\"CLOSE\",\"ticket\":%d,"
      "\"profit\":%.2f,\"reason\":\"%s\",\"ver\":\"v9\"}",
      _Symbol, ticket, profit, reason);
   char pd[], rd[];
   string h = BuildWebhookHeaders();
   string rs;
   StringToCharArray(json, pd, 0, StringLen(json));
   int res = WebRequest("POST", WebhookURL, h, 5000, pd, rd, rs);
   if(res == -1)
      Print("  [Webhook] SendClose FAILED (err=", GetLastError(), ") ตรวจสอบ URL/Secret");
   else
      Print("  [Webhook] Close sent: ticket=", ticket, " profit=$", DoubleToString(profit,2));
}

void SendWebhookSignal(string sig, double rsi, double adx, double lot, int htfTrend)
{
   string htfStr = (htfTrend ==  1) ? "BULL" :
                   (htfTrend == -1) ? "BEAR" : "FLAT";
   string json = StringFormat(
      "{\"sym\":\"%s\",\"sig\":\"%s\",\"rsi\":%.2f,\"adx\":%.1f,"
      "\"lot\":%.2f,\"bal\":%.2f,\"htf\":\"%s\",\"ver\":\"v9\"}",
      _Symbol, sig, rsi, adx, lot,
      AccountInfoDouble(ACCOUNT_BALANCE), htfStr);
   char pd[], rd[];
   string h = BuildWebhookHeaders();
   string rs;
   StringToCharArray(json, pd, 0, StringLen(json));
   int res = WebRequest("POST", WebhookURL, h, 5000, pd, rd, rs);
   if(res == -1)
      Print("  [Webhook] SendSignal FAILED (err=", GetLastError(), ") ตรวจสอบ URL/Secret");
   else
      Print("  [Webhook] Signal sent: ", sig, " lot=", DoubleToString(lot,2));
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   handleRSI = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
   handleATR = iATR(_Symbol, _Period, ATRPeriod);
   handleADX = iADX(_Symbol, _Period, ADXPeriod);

   // [FIX-3] HTF EMA handles
   handleHTF_EMA_Fast = iMA(_Symbol, HTF_Period, HTF_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleHTF_EMA_Slow = iMA(_Symbol, HTF_Period, HTF_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   // [v11-A] MTF handles
   handleD1_EMA      = iMA(_Symbol, PERIOD_D1, D1_EMA,      0, MODE_EMA, PRICE_CLOSE);
   handleH4_EMA_Fast = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleH4_EMA_Slow = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleRSI == INVALID_HANDLE || handleATR == INVALID_HANDLE ||
      handleADX == INVALID_HANDLE || handleHTF_EMA_Fast == INVALID_HANDLE ||
      handleHTF_EMA_Slow == INVALID_HANDLE ||
      handleD1_EMA == INVALID_HANDLE || handleH4_EMA_Fast == INVALID_HANDLE ||
      handleH4_EMA_Slow == INVALID_HANDLE)
   {
      Print("ERROR: indicator handles failed");
      return INIT_FAILED;
   }

   // ตรวจ RR ทันทีตอน init (ใช้ MinLotSize เพื่อ estimate commission)
   if(!CheckRRRatio(ProfitTargetUSD, StopLossUSD, MinLotSize)) {
      Print("WARNING: RR ratio ต่ำกว่า MinRR — ปรับ TP หรือ SL ด้วยครับ");
   }

   gPeakBalance = gDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   gTradeCount  = 0;
   gLastBarTime = 0;
   gConsecutiveLoss = 0;
   gConsLossBlockUntil = 0;

   Print("================================================");
   Print("  MT5 v11 — MTF TOP-DOWN + SMART RE-ENTRY + ADAPTIVE CONF");
   Print("------------------------------------------------");
   Print("  Symbol    : ", _Symbol);
   Print("  Timeframe : ", EnumToString(_Period));
   Print("--- [v11-A] Multi-Timeframe ---");
   Print("  1D EMA:", D1_EMA, " | 4H EMA:", H4_EMA_Fast, "/", H4_EMA_Slow);
   Print("  Use1D:", Use1DFilter, " Use4H:", Use4HFilter);
   Print("--- [v11-B] Re-entry ---");
   Print("  MinBars:", ReentryMinBars, " RetracePct:", ReentryZonePct, "%");
   Print("--- [v11-C] Adaptive Conf ---");
   Print("  LossBonus per loss: +", ConfLossBonus);
   Print("--- [FIX-8] Commission ---");
   Print("  CommissionPerLot: $", CommissionPerLot, " (round-trip x2)");
   Print("--- [FIX-1] TP/SL ---");
   Print("  TP: $", ProfitTargetUSD, " | SL: $", StopLossUSD,
         " | RR: ", DoubleToString(ProfitTargetUSD / StopLossUSD, 2), "x",
         " | Extended: $", ProfitExtendedUSD);
   Print("--- [FIX-2] Lot Calculation ---");
   Print("  Risk: ", RiskPercent, "% | pip-distance formula (fixed from v8)");
   Print("--- [FIX-3] HTF Filter ---");
   Print("  HTF: ", EnumToString(HTF_Period),
         " | EMA", HTF_EMA_Fast, "/", HTF_EMA_Slow,
         " | Active: ", UseHTFFilter);
   Print("--- [FIX-4] Cooldown ---");
   Print("  Cooldown: ", CooldownSeconds, "s (",
         DoubleToString(CooldownSeconds / 60.0, 1), " min)",
         " | ConsLoss block: ", MaxConsecutiveLoss, " ไม้ → หยุด ", ConsLossBlockMinutes, " นาที");
   Print("--- [FIX-5] OB Freshness ---");
   Print("  OB max age: ", OB_MaxAgeBars, " bars | broken OB excluded");
   Print("--- [FIX-6] RR Enforce ---");
   Print("  Min RR: ", DoubleToString(MinRR, 1), "x");
   Print("--- Price Action ---");
   Print("  OB:", UseOrderBlock, " FVG:", UseFVG, " Sweep:", UseLiqSweep,
         " VP:", UseVolumeProfile, " MS:", UseMarketStructure);
   Print("--- MM ---");
   Print("  Daily SL: ", DailyLossLimit, "% | Max DD: ", MaxDrawdownPct, "%");
   Print("  Max trades/day: ", MaxTradesPerDay);
   Print("================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleHTF_EMA_Fast);
   IndicatorRelease(handleHTF_EMA_Slow);
   IndicatorRelease(handleD1_EMA);
   IndicatorRelease(handleH4_EMA_Fast);
   IndicatorRelease(handleH4_EMA_Slow);
   Print("EA v9 Stopped | Trades:", gTradesToday, " | ConsLoss:", gConsecutiveLoss, " | Reason:", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // ATR ทุก tick
   double atrVal[]; ArraySetAsSeries(atrVal, true);
   if(CopyBuffer(handleATR, 0, 0, 1, atrVal) <= 0) return;
   double atr = atrVal[0];

   // DPL จัดการ position ที่เปิดอยู่
   ManageDPL(atr);

   // เช็คแท่งใหม่
   datetime barTimes[]; ArraySetAsSeries(barTimes, true);
   if(CopyTime(_Symbol, _Period, 0, 1, barTimes) <= 0) return;
   bool newBar = (barTimes[0] != gLastBarTime);

   if(newBar) {
      gLastBarTime = barTimes[0];
      DetectOrderBlocks(atr);
      DetectFVG(atr);
      BuildVolumeProfile();
      Print("  [Bar] PA updated | ", TimeToString(barTimes[0]));
   }

   // ความถี่เช็ค: ครึ่งหนึ่งของ period
   static datetime lastCheck = 0;
   int interval = (int)PeriodSeconds(_Period);
   if(TimeCurrent() - lastCheck < interval / 2) return;
   lastCheck = TimeCurrent();

   // ====== MM LIMITS ======
   if(!CheckDailyLimit() || !CheckDrawdown()) { gTradingHalted = true; return; }
   gTradingHalted = false;

   // [FIX-4] Consecutive loss block
   if(IsConsecutiveLossBlocked()) return;

   // ====== REGIME CHECK ======
   ENUM_MARKET_REGIME_V9 regime = DetectRegime();
   if(regime == REGIME_SIDEWAYS_V9) { Print("  [Regime] SIDEWAYS — skip"); return; }

   // ====== NEWS ======
   if(IsNewsBlackout()) return;

   // ====== SESSION ======
   if(!IsSessionOK()) return;

   // ====== SPREAD + VOLATILITY ======
   if(UseSpreadFilter && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;
   if(atr < MinATRFilter) return;

   // ====== TRADE LIMITS ======
   datetime now = TimeCurrent();
   MqlDateTime mdt; TimeToStruct(now, mdt);
   datetime today = now - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   if(today != gLastDayReset) { gTradesToday = 0; gLastDayReset = today; }
   if(gTradesToday >= MaxTradesPerDay) return;
   if(CountPositions() >= MaxPositions) return;
   if(CooldownSeconds > 0 && gLastTradeClose > 0 &&
      (int)(TimeCurrent() - gLastTradeClose) < CooldownSeconds) return;

   // ====== [FIX-3] HTF TREND CHECK ======
   int htfTrend = GetHTFTrend();

   // ====== RSI ======
   double rsiVal[]; ArraySetAsSeries(rsiVal, true);
   if(CopyBuffer(handleRSI, 0, 0, 1, rsiVal) <= 0) return;
   double rsi = rsiVal[0];

   // ====== ADX ======
   double adxBuf[]; ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(handleADX, 0, 0, 1, adxBuf) <= 0) return;
   double adx = adxBuf[0];

   // ====== PA ANALYSIS ======
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   PASignal paSig  = AnalyzePriceAction(atr, curPrice);

   // [v11-A] MTF Top-Down bias
   double mtfBuyBonus  = GetMTFBonus(true);
   double mtfSellBonus = GetMTFBonus(false);

   // [v11-C] Adaptive confidence threshold
   double minConf = GetMinConfidence(regime == REGIME_TRENDING_V9);

   // ====== ENTRY LOGIC ======
   // confidence จริง = PA conf + MTF bonus
   double buyConfFinal  = paSig.confidence + (mtfBuyBonus  > -99 ? mtfBuyBonus  : 0);
   double sellConfFinal = paSig.confidence + (mtfSellBonus > -99 ? mtfSellBonus : 0);

   bool buyReady  = paSig.hasBuySetup
                  && (rsi < RSIOBought)
                  && !paSig.hasSellSetup
                  && (buyConfFinal >= minConf)
                  && (htfTrend == 1 || !UseHTFFilter)
                  && (mtfBuyBonus  > -99)              // [v11-A] 1D ไม่สวน
                  && IsReentryReady(true);              // [v11-B] re-entry check

   bool sellReady = paSig.hasSellSetup
                  && (rsi > RSIOSold)
                  && !paSig.hasBuySetup
                  && (sellConfFinal >= minConf)
                  && (htfTrend == -1 || !UseHTFFilter)
                  && (mtfSellBonus > -99)              // [v11-A] 1D ไม่สวน
                  && IsReentryReady(false);             // [v11-B] re-entry check

   // ====== LOGGING ======
   string htfStr  = (htfTrend ==  1) ? "BULL" : (htfTrend == -1) ? "BEAR" : "FLAT";
   string regStr  = (regime == REGIME_TRENDING_V9) ? "TREND" : "CAUTION";
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   Print("--- ", _Symbol, " [", EnumToString(_Period), "] ---");
   Print("  ADX:", DoubleToString(adx, 1),
         " RSI:", DoubleToString(rsi, 2),
         " ATR:", DoubleToString(atr, 5),
         " Spd:", spread);
   Print("  Regime:", regStr,
         " | HTF:", htfStr,
         " | 1D:", Get1DBias()==1?"BULL":Get1DBias()==-1?"BEAR":"FLAT",
         " | 4H:", Get4HBias()==1?"BULL":Get4HBias()==-1?"BEAR":"FLAT");
   Print("  PA Conf:", DoubleToString(paSig.confidence, 2),
         " | BuyConf:", DoubleToString(buyConfFinal, 2),
         " | SellConf:", DoubleToString(sellConfFinal, 2),
         " | minConf:", DoubleToString(minConf, 2),
         " | Trades:", gTradesToday, "/", MaxTradesPerDay,
         " | ConsLoss:", gConsecutiveLoss);

   if(buyReady) {
      Print(">>> BUY | PA:[", paSig.reasons, "] Conf:", DoubleToString(paSig.confidence, 2),
            " | HTF:", htfStr, " | RSI:", DoubleToString(rsi, 2));
      if(AutoTrade) {
         ExecuteTrade(ORDER_TYPE_BUY, atr, paSig);
         SendWebhookSignal("BUY", rsi, adx, CalcLotSize(StopLossUSD), htfTrend);
      }
   }
   else if(sellReady) {
      Print(">>> SELL | PA:[", paSig.reasons, "] Conf:", DoubleToString(paSig.confidence, 2),
            " | HTF:", htfStr, " | RSI:", DoubleToString(rsi, 2));
      if(AutoTrade) {
         ExecuteTrade(ORDER_TYPE_SELL, atr, paSig);
         SendWebhookSignal("SELL", rsi, adx, CalcLotSize(StopLossUSD), htfTrend);
      }
   }
}
//+------------------------------------------------------------------+
