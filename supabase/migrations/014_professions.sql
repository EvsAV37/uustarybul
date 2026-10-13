-- 014 — сферы деятельности как профессии (13.10.2026)
-- Справочник categories: профессия (или название услуги, где профессии нет),
-- множественное число, короткое имя для плитки, группа, показ на главной,
-- слова для поиска и подсказки для формы. Название направления = название сферы
-- (ставит триггер), поиск учитывает слова работы.

alter table public.categories
  add column if not exists name_plural  text,
  add column if not exists short_name   text,
  add column if not exists grp          text,
  add column if not exists on_home      boolean not null default false,
  add column if not exists keywords     text not null default '',
  add column if not exists hint_service text,
  add column if not exists hint_unit    text,
  add column if not exists hint_query   text;

grant select (name_plural, short_name, grp, on_home, keywords, hint_service, hint_unit, hint_query)
  on public.categories to anon, authenticated;

-- Справочник: старые 14 записей переименовываются (id и связи сохраняются), новые добавляются
create temp table _c (id int, slug text, name text, name_plural text, short_name text, grp text, sort int,
                      on_home bool, keywords text, hint_service text, hint_unit text, hint_query text) on commit drop;
insert into _c values
-- Дом и ремонт
(2,    'santehnik',      'Сантехник', 'Сантехники', null, 'Дом и ремонт', 10, true,
 'сантехника водопровод канализация отопление трубы смеситель унитаз ванна бойлер водонагреватель засор радиатор батарея', 'Замена смесителя', 'за шт.', 'бойлер или засор'),
(3,    'elektrik',       'Электрик', 'Электрики', null, 'Дом и ремонт', 20, true,
 'электрика электромонтаж проводка розетка выключатель щиток автомат счётчик освещение люстра', 'Замена розетки', 'за шт.', 'проводка или щиток'),
(4,    'svarshchik',     'Сварщик', 'Сварщики', null, 'Дом и ремонт', 30, true,
 'сварка сварочные работы металл металлоконструкции ворота забор навес калитка', 'Сварка ворот', 'договорная', 'ворота или навес'),
(1,    'stroitel',       'Строитель-отделочник', 'Строители-отделочники', 'Строитель', 'Дом и ремонт', 40, true,
 'ремонт стройка строительство отделка утепление гипсокартон штукатурка плитка обои ламинат окна кровля фундамент', 'Укладка плитки', 'за м²', 'плитка или утепление'),
(null, 'plotnik',        'Плотник', 'Плотники', null, 'Дом и ремонт', 50, false,
 'плотницкие столяр дерево сруб баня крыша кровля пол крыльцо двери', 'Сборка сруба', 'договорная', 'сруб или баня'),
(null, 'pechnik',        'Печник', 'Печники', null, 'Дом и ремонт', 60, false,
 'печь печка камин дымоход труба кладка банная печь', 'Кладка печи', 'договорная', 'печь или дымоход'),
(null, 'remont-tehniki', 'Ремонт бытовой техники', 'Ремонт бытовой техники', 'Ремонт техники', 'Дом и ремонт', 70, false,
 'бытовая техника холодильник морозильник стиральная машина плита духовка микроволновка телевизор', 'Ремонт стиральной машины', 'за выезд', 'холодильник или стиральная'),
(null, 'remont-telefonov','Ремонт телефонов и компьютеров', 'Ремонт телефонов и компьютеров', 'Ремонт телефонов', 'Дом и ремонт', 80, false,
 'телефон смартфон компьютер ноутбук планшет экран стекло аккумулятор прошивка', 'Замена экрана телефона', 'за шт.', 'экран или ноутбук'),
-- Авто
(5,    'avtomehanik',    'Автомеханик', 'Автомеханики', null, 'Авто', 110, true,
 'авто автомобиль машина ремонт авто автосервис ходовая подвеска двигатель масло тормоза', 'Замена масла', 'за шт.', 'ходовая или масло'),
(null, 'avtoelektrik',   'Автоэлектрик', 'Автоэлектрики', null, 'Авто', 120, false,
 'авто автомобиль электрика автомобиля стартер генератор сигнализация автозапуск диагностика', 'Установка автозапуска', 'за шт.', 'стартер или автозапуск'),
(null, 'shinomontazh',   'Шиномонтаж', 'Шиномонтаж', null, 'Авто', 130, false,
 'шины колёса колеса резина переобувка балансировка вулканизация прокол', 'Переобувка', 'за колесо', 'переобувка или балансировка'),
-- Здоровье
(9,    'medsestra',      'Медсестра', 'Медсёстры', null, 'Здоровье', 210, true,
 'здоровье медсестра медбрат медицинская помощь на дому уколы инъекции капельница перевязка давление', 'Уколы на дому', 'за выезд', 'уколы или капельница'),
(null, 'massazhist',     'Массажист', 'Массажисты', null, 'Здоровье', 220, false,
 'массаж лечебный классический спина шея детский', 'Массаж спины', 'за сеанс', 'массаж спины'),
(null, 'sidelka',        'Сиделка', 'Сиделки', null, 'Здоровье', 230, false,
 'сиделка уход за пожилыми лежачий больной присмотр', 'Уход за пожилым человеком', 'за час', 'уход за пожилым'),
-- Красота
(null, 'parikmaher',     'Парикмахер', 'Парикмахеры', null, 'Красота', 310, false,
 'стрижка причёска прическа окрашивание укладка барбер', 'Мужская стрижка', 'за шт.', 'стрижка или окрашивание'),
(10,   'manikyur',       'Мастер маникюра', 'Мастера маникюра', null, 'Красота', 320, false,
 'красота маникюр педикюр ногти гель-лак наращивание', 'Маникюр с покрытием', 'за шт.', 'педикюр или наращивание'),
(null, 'kosmetolog',     'Косметолог', 'Косметологи', null, 'Красота', 330, false,
 'косметология чистка лица уход за кожей брови ресницы', 'Чистка лица', 'за процедуру', 'чистка лица или брови'),
-- Обучение
(11,   'repetitor',      'Репетитор', 'Репетиторы', null, 'Обучение', 410, true,
 'обучение учитель занятия математика русский язык английский физика химия огэ егэ подготовка к школе', 'Математика ЕГЭ', 'за час', 'математика или ЕГЭ'),
(null, 'logoped',        'Логопед', 'Логопеды', null, 'Обучение', 420, false,
 'речь звуки постановка звуков дефектолог занятия с ребёнком', 'Постановка звуков', 'за занятие', 'постановка звуков'),
-- Услуги
(7,    'vyvoz-musora',   'Вывоз мусора', 'Вывоз мусора', null, 'Услуги', 510, false,
 'мусор тбо строймусор вывоз хлама', 'Вывоз строймусора', 'за машину', 'строймусор'),
(8,    'septik',         'Откачка септика', 'Откачка септика', null, 'Услуги', 520, false,
 'септик выгребная яма ассенизатор откачка канализации', 'Откачка до 4 м³', 'за машину', 'выгребная яма'),
(6,    'drova',          'Дрова и пиломатериалы', 'Дрова и пиломатериалы', null, 'Услуги', 530, true,
 'дрова брус доска пиломатериал лес горбыль чурки', 'Дрова колотые', 'за машину', 'брус или доска'),
(null, 'gruzoperevozki', 'Грузоперевозки', 'Грузоперевозки', null, 'Услуги', 540, false,
 'переезд грузчики газель перевозка доставка груза', 'Переезд по городу', 'за час', 'переезд или грузчики'),
(14,   'uborka',         'Уборка', 'Уборка', null, 'Услуги', 550, false,
 'бытовые услуги клининг генеральная уборка мытьё окон', 'Генеральная уборка', 'за м²', 'мытьё окон'),
(null, 'remont-odezhdy', 'Ремонт одежды и обуви', 'Ремонт одежды и обуви', 'Ремонт одежды', 'Услуги', 560, false,
 'швея ателье пошив подшить молния ремонт обуви', 'Замена молнии', 'за шт.', 'молния или подшить'),
(null, 'fotograf',       'Фотограф', 'Фотографы', null, 'Услуги', 570, false,
 'фото фотосессия фотосъёмка съёмка свадьба выпускной', 'Фотосессия', 'за час', 'фотосессия или свадьба'),
(null, 'torty',          'Торты и выпечка', 'Торты и выпечка', null, 'Услуги', 580, false,
 'торт кондитер выпечка пироги на заказ', 'Торт на заказ', 'за кг', 'торт или пироги'),
(12,   'yurist',         'Юрист', 'Юристы', null, 'Услуги', 590, false,
 'юридические услуги адвокат консультация договор иск суд', 'Консультация', 'за час', 'договор или иск'),
(13,   'strahovoy-agent','Страховой агент', 'Страховые агенты', null, 'Услуги', 600, false,
 'страхование осаго каско полис', 'ОСАГО', 'договорная', 'ОСАГО или КАСКО');

-- Триггер сферы: название = название сферы деятельности, в поиск — мн. число и слова работы
create or replace function public.tg_spheres_before()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_cat record; v_services text; v_catwords text;
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.spheres where profile_id = new.profile_id) >= 20 then
      raise exception 'spheres_total_limit' using errcode = 'P0001', hint = 'Не больше 20 сфер в профиле';
    end if;
  end if;
  select name, name_plural, keywords into v_cat from public.categories where id = new.category_id;
  if v_cat.name is not null then new.title := v_cat.name; end if;
  v_catwords := coalesce(v_cat.name_plural, '') || ' ' || coalesce(v_cat.keywords, '');
  select coalesce(string_agg(title, ' ' order by sort), '') into v_services
  from public.services where sphere_id = new.id;
  new.search_text := lower(new.title || ' ' || v_catwords || ' ' || v_services);
  new.search_doc := setweight(to_tsvector('russian', new.title), 'A')
                 || setweight(to_tsvector('russian', v_catwords || ' ' || v_services), 'B')
                 || setweight(to_tsvector('russian', coalesce(new.description, '')), 'C');
  return new;
end $function$;

-- Правка справочника (название, слова) сразу обновляет названия и поиск направлений
create or replace function public.tg_categories_reindex()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  update public.spheres set category_id = category_id where category_id = new.id;
  return null;
end $function$;

create or replace trigger categories_reindex after update of name, name_plural, keywords on public.categories
  for each row execute function public.tg_categories_reindex();

-- Данные справочника. Переименование сферы через триггер categories_reindex
-- сразу обновляет названия и поиск всех её направлений.
update public.categories c set slug=_c.slug, name=_c.name, name_plural=_c.name_plural, short_name=_c.short_name,
  grp=_c.grp, sort=_c.sort, on_home=_c.on_home, keywords=_c.keywords, hint_service=_c.hint_service,
  hint_unit=_c.hint_unit, hint_query=_c.hint_query, icon=_c.slug, is_active=true
from _c where _c.id = c.id;

insert into public.categories (slug, name, name_plural, short_name, grp, sort, on_home, keywords, hint_service, hint_unit, hint_query, is_active, icon)
select slug, name, name_plural, short_name, grp, sort, on_home, keywords, hint_service, hint_unit, hint_query, true, slug
from _c where id is null;
