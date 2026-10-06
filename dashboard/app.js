// Datos ilustrativos del mockup. En producción vendrían de las vistas y funciones del esquema dm.

// vw_kpi_equipo
const equipos = [
  ["T1", 68], ["Gen.G", 63], ["HLE", 57], ["KT", 52], ["DK", 46], ["BRO", 39],
];

// vw_presencia_campeon / fn_top_campeones(parche, limite)
const campeones = [
  ["Campeón A", 94.7, 48, 132, 56.3, "Jungla"],
  ["Campeón B", 81.2, 96, 58, 52.1, "Medio"],
  ["Campeón C", 74.5, 112, 29, 47.3, "Superior"],
  ["Campeón D", 68.9, 88, 42, 54.0, "Tirador"],
  ["Campeón E", 61.4, 74, 35, 45.8, "Soporte"],
];

const pct = n => n.toFixed(1).replace(".", ",") + " %";
const max = Math.max(...equipos.map(([, wr]) => wr));

document.getElementById("barras").innerHTML = equipos
  .map(([, wr]) => `<div class="barra"><b>${wr}%</b><i style="height:${(wr / max) * 85}%"></i></div>`)
  .join("");

document.getElementById("eje").innerHTML = equipos
  .map(([nombre]) => `<span>${nombre}</span>`)
  .join("");

document.getElementById("campeones").innerHTML = campeones
  .map(([nombre, presencia, picks, bans, wr, pos]) => `<tr>
    <td>${nombre}</td><td>${pct(presencia)}</td><td>${picks}</td><td>${bans}</td>
    <td><span class="pill${wr < 50 ? " baja" : ""}">${pct(wr)}</span></td><td>${pos}</td>
  </tr>`)
  .join("");
