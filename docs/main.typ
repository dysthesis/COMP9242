#import "lib.typ": ams-article, proof, theorem
#import "@preview/algorithmic:1.0.3"
#import "@preview/ctheorems:1.1.3": *
#import "@preview/cetz:0.4.1"
#show: thmrules.with(qed-symbol: $square$)

#let cons = $||$

#set quote(block: true)
#let problem(it) = smallcaps(it)
#let paragraph(title) = strong[#title.  ]
#set enum(numbering: "1.a.i.")

#show link: underline
#show link: set text(fill: blue)

#set heading(numbering: "1.1.")

#import algorithmic: algorithm-figure, style-algorithm
#let theorem = thmbox("theorem", "Theorem", fill: rgb("#eeffee"))
#let corollary = thmplain(
  "corollary",
  "Corollary",
  base: "theorem",
  titlefmt: strong,
)
#let definition = thmbox("definition", "Definition", inset: (x: 1.2em))

#let example = thmplain("example", "Example").with(numbering: none)
#let proof = thmproof("proof", "Proof")
#let lemma = thmbox(
  "theorem", // identifier - same as that of theorem
  "Lemma", // head
  fill: rgb("#d3d3d3"),
)
#show: ams-article.with(title: [SOS Design Documentation], authors: (
  (
    name: "Antheo Raviel Santosa",
  ),
  (
    name: "Morgan Swaak",
  ),
))

#let styled-box(body) = block(below: 0.65em, body)

#let question(body) = styled-box(rect(
  radius: 5pt,
  inset: (y: 0.8em, x: 0.8em),
  stroke: 1pt + luma(180),
  width: 100%,
  body,
))

#let solution(body) = styled-box(rect(
  stroke: 1pt + luma(180),
  fill: rgb("#e5f5e0"),
  radius: 5pt,
  inset: 0.8em,
  width: 100%,
  [*Solution.*  #body],
))

#include "chapters/milestone_1.typ"
