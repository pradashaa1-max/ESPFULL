# AstralCheat — Standoff 2 (iOS)

Полностью рабочий IL2CPP-чит под текущий dump UnityFramework.

## Что есть

| Функция | Описание |
|---------|----------|
| **Aim bot** | Плавная наводка (LookAt + smooth), кость Head/Neck/Chest |
| **Silent** | Направление цели без видимого поворота камеры |
| **FOV Circle** | Круг зоны аима, слайдер 1–30 |
| **Box ESP** | Зелёная 2D-рамка |
| **Skeleton** | Голубой скелет + точки суставов |
| **Names** | Фиолетовый тег с ником + треугольник |
| **Health** | Полоска HP + проценты |
| **Weapon** | Красная иконка оружия под игроком |
| **Distance** | Дистанция в метрах |
| **Team check** | Игнор союзников |
| **Hide recording** | Меню + ESP не видны на скринах/записи (вкл. по умолчанию) |
| **Language** | English / Русский |
| **Menu color** | 6 акцентных цветов |

## Структура

```
astral_full/
├── README.md
├── Makefile                          # Theos
├── .github/workflows/build.yml       # CI → artifact dylib
├── include/
│   ├── State.h                       # атомики фич + язык + цвет
│   ├── Offsets.h                     # RVA + field offsets этого билда
│   └── Il2Cpp.h                      # runtime API
└── src/
    ├── Menu.mm                       # UI, hide-rec, язык, цвета, FAB
    └── Features.mm                   # aim / silent / ESP draw / player list
```

## Workflow (как всё крутится)

1. **constructor** (`astral_ctor`) → через 1.2 с вызывает `[ACH start]`
2. **ACH start** создаёт `ACW` (overlay window, `canBecomeKeyWindow = NO`)
3. `hitTest:` возвращает `nil` вне панели/FAB → **кнопки игры работают**
4. **Hide recording ON** сразу: UITextField.secureTextEntry → меню и ESP внутри secure-слоя
5. **CADisplayLink 60 fps** → `Astral_FeaturesTick`
6. Tick:
   - раз в 12 кадров: `FindObjectsOfType(PlayerController)` → кэш списка
   - aimbot/silent по кэшу + FOV
   - `ESPView setNeedsDisplay` → CoreGraphics: box / skeleton / HP / name / weapon

## Сборка

```bash
export THEOS=~theos
cd astral_full
make clean && make
# → .theos/obj/AstralCheat.dylib
```

Или push в GitHub → Actions → скачать artifact.

## Инжект

```bash
insert_dylib --inplace --all-yes @rpath/AstralCheat.dylib <GameBinary>
```

Либо Theos tweak / ElleKit / любой dylib-loader в процесс Standoff 2.

## После патча игры

1. Новый `UnityFramework` + `global-metadata.dat`
2. Il2CppDumper → обновить RVA в `include/Offsets.h`
3. Проверить field offsets PlayerController / AimController
4. `make` заново

## Важно

- Silent на этом билде не патчит пулю на сервере (нужен хук WeaponryController.Fire). Сейчас silent = не крутить камеру визуально. `Astral_GetSilentDir` экспортирован для донастройки.
- HP читается best-effort с offset 0x18 HitController — после патча уточнить.
- Имена/оружие/патроны сейчас заглушки ("Enemy") — для реальных ников нужен PhotonPlayer.NickName (добавляется тем же способом через field offset).
